--[[
    Parallel Chat Translator
    ------------------------
    Outgoing : you type into the translator's own input bar. What you type is
               translated, then sent. Roblox's default chat bar is driven by a
               CoreScript in a separate Luau VM, so an executor hook cannot
               intercept it -- owning the input is the only reliable route.
    Incoming : other players' messages are translated into your language and
               shown as an extra line.

    Commands, typed into the translator bar:
        >ja  >es  >pt-br ...   set OUTGOING language + enable
        >d                     disable outgoing translation
        >in en                 set INCOMING language + enable
        >in off                disable incoming translation
        >tr                    show current status
        >help                  show commands
]]

local Players           = game:GetService("Players")
local HttpService       = game:GetService("HttpService")
local TextChatService   = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui        = game:GetService("StarterGui")
local LocalPlayer       = Players.LocalPlayer

local env = (getgenv and getgenv()) or _G

--------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------
-- An older version of this script installed a namecall hook that cannot be
-- uninstalled for the rest of the session. It reads outEnabled off the shared
-- state table, so it would intercept this version's own SendAsync call and
-- translate an already-translated message. Park it by clearing the flag it
-- keys on, and keep this version's state under a separate name.
local legacy = env.__ChatTranslatorState
if type(legacy) == "table" then legacy.outEnabled = false end

local state = env.__ChatTranslatorStateV2 or {
    outEnabled = false,
    outLang    = "en",
    inEnabled  = true,
    inLang     = "en",
}
env.__ChatTranslatorStateV2 = state

-- Tear down a previous run's UI so re-executing does not stack input bars.
if env.__ChatTranslatorGui then
    pcall(function() env.__ChatTranslatorGui:Destroy() end)
    env.__ChatTranslatorGui = nil
end

--------------------------------------------------------------------------
-- HTTP
--------------------------------------------------------------------------
local requestFn = (syn and syn.request) or (http and http.request) or http_request or request

-- Returns body, or nil plus a reason string. Every transport this executor
-- might expose is tried in turn: request() exists on some executors but is
-- blocked or broken there while HttpGet still works, so failing one must not
-- abandon the others. The reason is surfaced to the user, since "translation
-- failed" on its own is not diagnosable.
-- Google answers a rate-limited or unconsented caller with an HTML page (a
-- "Sorry..." interstitial or a consent form) under HTTP 200. That is never a
-- valid reply from a JSON endpoint, so an HTML body counts as a failure and the
-- next transport or endpoint gets a turn, instead of the HTML reaching
-- JSONDecode and surfacing as an unexplained translation failure.
local function isHtml(body)
    -- JSON always opens with { or [; only markup opens with <. Matching on the
    -- first non-space character avoids flagging a translation that merely
    -- contains a tag-like substring.
    return body:match("^%s*(.)") == "<"
end

local function httpGet(url)
    local reasons = {}

    local function usable(body, label)
        if type(body) ~= "string" or body == "" then
            reasons[#reasons + 1] = label .. " empty"
            return nil
        end
        if isHtml(body) then
            reasons[#reasons + 1] = label .. " got HTML (blocked/consent)"
            return nil
        end
        return body
    end

    local ok, body = pcall(function() return game:HttpGet(url, true) end)
    if ok then
        local good = usable(body, "HttpGet")
        if good then return good end
    else
        reasons[#reasons + 1] = "HttpGet " .. tostring(body)
    end

    -- Only request() can set headers, and the CONSENT cookie is what clears
    -- Google's consent interstitial -- the same trick Nameless Admin uses.
    if requestFn then
        local rok, res = pcall(requestFn, {
            Url = url,
            Method = "GET",
            Headers = { cookie = "CONSENT=YES+" },
        })
        if rok and type(res) == "table" then
            local good = usable(res.Body or res.body, "request")
            if good then return good end
        else
            reasons[#reasons + 1] = "request " .. tostring(res)
        end
    end

    local gok, gbody = pcall(function() return HttpService:GetAsync(url, true) end)
    if gok then
        local good = usable(gbody, "GetAsync")
        if good then return good end
    else
        reasons[#reasons + 1] = "GetAsync " .. tostring(gbody)
    end

    return nil, table.concat(reasons, " | ")
end

--------------------------------------------------------------------------
-- Translation
--------------------------------------------------------------------------
local cache = {}

-- The plain gtx endpoint gets rate limited and then answers with an HTML
-- "Sorry..." interstitial rather than JSON, which is indistinguishable from a
-- translation failure. The dict-chrome-ex endpoint returns structured JSON and
-- held up when gtx was already blocked, so it leads and gtx is the fallback.
local ENDPOINTS = {
    {
        url = "https://clients5.google.com/translate_a/single?dj=1&dt=t&sl=auto&ie=UTF-8&oe=UTF-8&client=dict-chrome-ex&tl=%s&q=%s",
        parse = function(data)
            if type(data.sentences) ~= "table" then return nil end
            local parts = {}
            for _, sentence in ipairs(data.sentences) do
                if type(sentence.trans) == "string" then
                    parts[#parts + 1] = sentence.trans
                end
            end
            if #parts == 0 then return nil end
            return table.concat(parts),
                   (type(data.src) == "string" and data.src) or "auto"
        end,
    },
    {
        url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=%s&dt=t&q=%s",
        parse = function(data)
            if type(data[1]) ~= "table" then return nil end
            -- data[1] is a list of sentence chunks; joining keeps long messages whole.
            local parts = {}
            for _, chunk in ipairs(data[1]) do
                if type(chunk) == "table" and type(chunk[1]) == "string" then
                    parts[#parts + 1] = chunk[1]
                end
            end
            if #parts == 0 then return nil end
            local detected = (type(data[3]) == "string" and data[3])
                          or (type(data[2]) == "string" and data[2])
                          or "auto"
            return table.concat(parts), detected
        end,
    },
}

-- Returns translatedText, detectedSourceLang, or nil plus a reason.
local function translate(text, target)
    local key = target .. "\0" .. text
    local hit = cache[key]
    if hit then return hit[1], hit[2] end

    local encodedTarget = HttpService:UrlEncode(target)
    local encodedText   = HttpService:UrlEncode(text)
    local reasons = {}

    for _, endpoint in ipairs(ENDPOINTS) do
        local body, reason = httpGet(string.format(endpoint.url, encodedTarget, encodedText))
        if body then
            local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
            if ok and type(data) == "table" then
                local out, detected = endpoint.parse(data)
                if out then
                    cache[key] = { out, detected }
                    return out, detected
                end
                reasons[#reasons + 1] = "no text in reply"
            else
                reasons[#reasons + 1] = "not JSON: " .. body:sub(1, 50)
            end
        else
            reasons[#reasons + 1] = tostring(reason)
        end
    end

    return nil, table.concat(reasons, " | ")
end

--------------------------------------------------------------------------
-- Chat plumbing
--------------------------------------------------------------------------
local function getChannel()
    local channels = TextChatService:FindFirstChild("TextChannels")
    if not channels then return nil end
    local general = channels:FindFirstChild("RBXGeneral")
    if general then return general end
    for _, ch in ipairs(channels:GetChildren()) do
        if ch:IsA("TextChannel") then return ch end
    end
    return nil
end

-- Plain text: some games style the chat window with rich text disabled, and
-- markup then shows up literally.
local function feed(text)
    local channel = getChannel()
    if channel then
        local ok = pcall(function() channel:DisplaySystemMessage("[TR] " .. text) end)
        if ok then return end
    end
    pcall(function()
        StarterGui:SetCore("ChatMakeSystemMessage", {
            Text  = "[TR] " .. text,
            Color = Color3.fromRGB(0, 255, 204),
        })
    end)
end

local function sendToServer(text)
    local channel = getChannel()
    if channel then
        local ok, err = pcall(function() channel:SendAsync(text) end)
        if ok then return true end
        feed("send failed: " .. tostring(err))
        return false
    end

    local events = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
    local remote = events and events:FindFirstChild("SayMessageRequest")
    if remote and remote:IsA("RemoteEvent") then
        pcall(function() remote:FireServer(text, "All") end)
        return true
    end

    feed("no way to send found")
    return false
end

--------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------
local refreshBadge -- set once the UI exists

local function statusText()
    return string.format("out %s (%s) | in %s (%s)",
        state.outEnabled and "ON" or "OFF", state.outLang:upper(),
        state.inEnabled  and "ON" or "OFF", state.inLang:upper())
end

-- Returns true if the text was a command and must not be sent.
local function handleCommand(text)
    local lower = text:lower():match("^%s*(.-)%s*$")

    if lower == ">d" or lower == ">off" then
        state.outEnabled = false
        feed("Outgoing translation OFF.")
        return true
    end

    if lower == ">tr" then
        feed(statusText())
        return true
    end

    if lower == ">help" then
        feed(">xx set lang | >d off | >in xx | >in off | >tr status")
        return true
    end

    local incoming = lower:match("^>in%s+([%a%-]+)$")
    if incoming then
        if incoming == "off" then
            state.inEnabled = false
            feed("Incoming translation OFF.")
        else
            state.inLang    = incoming
            state.inEnabled = true
            feed("Incoming translation ON -> [" .. incoming:upper() .. "]")
        end
        return true
    end

    local outgoing = lower:match("^>([%a][%a%-]*)$")
    if outgoing and #outgoing <= 5 then
        state.outLang    = outgoing
        state.outEnabled = true
        feed("Outgoing translation ON -> [" .. outgoing:upper() .. "]")
        return true
    end

    return false
end

local function submitText(text)
    if type(text) ~= "string" then return end
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return end

    task.spawn(function()
        if handleCommand(text) then
            if refreshBadge then refreshBadge() end
            return
        end

        if state.outEnabled and text:sub(1, 1) ~= "/" then
            local translated, reason = translate(text, state.outLang)
            if translated then
                sendToServer(translated)
            else
                feed("Translation failed - sent original. " .. tostring(reason):sub(1, 160))
                sendToServer(text)
            end
        else
            sendToServer(text)
        end
    end)
end

--------------------------------------------------------------------------
-- Native chat box interception
--------------------------------------------------------------------------
-- The CoreScript that calls SendAsync is unreachable from this VM, but the
-- TextBox it reads is not: Roblox's input bar is an ordinary GUI under
-- CoreGui.ExperienceChat. Taking the text and blanking the box before the
-- CoreScript's own handler reads it replaces the message without any hook.
local function attachNativeChat()
    local CoreGui = game:GetService("CoreGui")

    local experienceChat = CoreGui:WaitForChild("ExperienceChat", 20)
    if not experienceChat then return false, "ExperienceChat not found" end

    local ok, box, button = pcall(function()
        local container = experienceChat:WaitForChild("appLayout", 10)
            :WaitForChild("chatInputBar", 10)
            :WaitForChild("Background", 10)
            :WaitForChild("Container", 10)
        local textContainer = container:WaitForChild("TextContainer", 10)
        return textContainer:WaitForChild("TextBoxContainer", 10):WaitForChild("TextBox", 10),
               container:WaitForChild("SendButton", 10)
    end)
    if not ok then return false, tostring(box) end
    if not box then return false, "TextBox not found" end

    local function grab()
        local text = box.Text
        if text == "" then return end
        box.Text = ""
        submitText(text)
    end

    box.FocusLost:Connect(function(enterPressed)
        if enterPressed then grab() end
    end)
    if button then
        button.MouseButton1Click:Connect(grab)
    end

    return true
end

--------------------------------------------------------------------------
-- Input bar
--------------------------------------------------------------------------
local function buildUI()
    local parent = (gethui and gethui()) or game:GetService("CoreGui")

    local gui = Instance.new("ScreenGui")
    gui.Name             = "ChatTranslatorInput"
    gui.ResetOnSpawn     = false
    gui.IgnoreGuiInset   = true
    gui.DisplayOrder     = 999
    gui.ZIndexBehavior   = Enum.ZIndexBehavior.Sibling

    local ok = pcall(function() gui.Parent = parent end)
    if not ok then
        gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    end
    if syn and syn.protect_gui then pcall(syn.protect_gui, gui) end
    env.__ChatTranslatorGui = gui

    local bar = Instance.new("Frame")
    bar.Name                   = "Bar"
    bar.AnchorPoint            = Vector2.new(0.5, 1)
    bar.Position               = UDim2.new(0.5, 0, 1, -110)
    bar.Size                   = UDim2.new(0.72, 0, 0, 46)
    bar.BackgroundColor3       = Color3.fromRGB(24, 26, 30)
    bar.BackgroundTransparency = 0.12
    bar.BorderSizePixel        = 0
    bar.Parent                 = gui
    Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 10)

    local box = Instance.new("TextBox")
    box.Name                   = "Input"
    box.Position               = UDim2.new(0, 12, 0, 0)
    box.Size                   = UDim2.new(1, -150, 1, 0)
    box.BackgroundTransparency = 1
    box.ClearTextOnFocus       = false
    box.Text                   = ""
    box.PlaceholderText        = "type here to translate & send"
    box.PlaceholderColor3      = Color3.fromRGB(140, 145, 155)
    box.TextColor3             = Color3.fromRGB(240, 242, 245)
    box.TextSize               = 18
    box.Font                   = Enum.Font.GothamMedium
    box.TextXAlignment         = Enum.TextXAlignment.Left
    box.TextTruncate           = Enum.TextTruncate.AtEnd
    box.Parent                 = bar

    local badge = Instance.new("TextLabel")
    badge.Name                   = "Badge"
    badge.AnchorPoint            = Vector2.new(1, 0.5)
    badge.Position               = UDim2.new(1, -84, 0.5, 0)
    badge.Size                   = UDim2.new(0, 48, 0, 26)
    badge.BackgroundColor3       = Color3.fromRGB(45, 48, 55)
    badge.BorderSizePixel        = 0
    badge.TextColor3             = Color3.fromRGB(0, 255, 204)
    badge.TextSize               = 14
    badge.Font                   = Enum.Font.GothamBold
    badge.Text                   = "OFF"
    badge.Parent                 = bar
    Instance.new("UICorner", badge).CornerRadius = UDim.new(0, 6)

    local send = Instance.new("TextButton")
    send.Name             = "Send"
    send.AnchorPoint      = Vector2.new(1, 0.5)
    send.Position         = UDim2.new(1, -8, 0.5, 0)
    send.Size             = UDim2.new(0, 68, 0, 32)
    send.BackgroundColor3 = Color3.fromRGB(0, 145, 120)
    send.BorderSizePixel  = 0
    send.AutoButtonColor  = true
    send.TextColor3       = Color3.fromRGB(255, 255, 255)
    send.TextSize         = 15
    send.Font             = Enum.Font.GothamBold
    send.Text             = "Send"
    send.Parent           = bar
    Instance.new("UICorner", send).CornerRadius = UDim.new(0, 8)

    local toggle = Instance.new("TextButton")
    toggle.Name             = "Toggle"
    toggle.AnchorPoint      = Vector2.new(0.5, 1)
    toggle.Position         = UDim2.new(0.5, 0, 1, -164)
    toggle.Size             = UDim2.new(0, 44, 0, 24)
    toggle.BackgroundColor3 = Color3.fromRGB(24, 26, 30)
    toggle.BackgroundTransparency = 0.2
    toggle.BorderSizePixel  = 0
    toggle.TextColor3       = Color3.fromRGB(200, 205, 215)
    toggle.TextSize         = 13
    toggle.Font             = Enum.Font.GothamBold
    toggle.Text             = "hide"
    toggle.Parent           = gui
    Instance.new("UICorner", toggle).CornerRadius = UDim.new(0, 6)

    refreshBadge = function()
        badge.Text = state.outEnabled and state.outLang:upper() or "OFF"
    end
    refreshBadge()

    local function submit()
        local text = box.Text
        box.Text = ""
        submitText(text)
    end

    box.FocusLost:Connect(function(enterPressed)
        if enterPressed then submit() end
    end)
    send.MouseButton1Click:Connect(submit)

    toggle.MouseButton1Click:Connect(function()
        bar.Visible = not bar.Visible
        toggle.Text = bar.Visible and "hide" or "show"
    end)

    return gui
end

local uiOk, uiErr = pcall(buildUI)

--------------------------------------------------------------------------
-- Incoming translation
--------------------------------------------------------------------------
local seen = {}

local function showIncoming(speaker, original, target)
    local translated, detected = translate(original, target)
    if not translated then return end
    if detected == target then return end
    if translated:lower() == original:lower() then return end
    feed(string.format("%s [%s]: %s", speaker, detected:upper(), translated))
end

-- MessageReceived rather than the OnIncomingMessage callback property: it is a
-- plain event, so it carries no no-yield restriction and does not fight another
-- script for ownership of a single callback slot.
TextChatService.MessageReceived:Connect(function(message)
    if not state.inEnabled then return end

    local source = message.TextSource
    if not source then return end
    if source.UserId == LocalPlayer.UserId then return end

    local text = message.Text
    if not text or text == "" then return end
    if seen[message.MessageId] then return end
    seen[message.MessageId] = true

    local player = Players:GetPlayerByUserId(source.UserId)
    local name = player and player.DisplayName or "?"

    task.spawn(showIncoming, name, text, state.inLang)
end)

--------------------------------------------------------------------------
task.spawn(function()
    local attached, why = attachNativeChat()
    if attached then
        feed("Game's own chat box hooked - you can type there or in the bar.")
    else
        feed("Game's chat box not hooked (" .. tostring(why) .. ") - use the bar.")
    end
end)

feed("Loaded.")
feed("Try >ja then type a message. " .. statusText())
if not uiOk then
    feed("INPUT BAR FAILED: " .. tostring(uiErr))
end
