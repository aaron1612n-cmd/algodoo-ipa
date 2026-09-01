--[[
    Parallel Chat Translator
    ------------------------
    Outgoing : your messages are translated before they reach the server.
    Incoming : other players' messages are translated into your language
               and shown as an extra line under the original.

    Commands (typed into normal chat, they are swallowed and never sent):
        >ja  >es  >pt-br ...   set OUTGOING language + enable
        >d                     disable outgoing translation
        >in en                 set INCOMING language + enable
        >in off                disable incoming translation
        >tr                    show current status
        >help                  show commands

    Requires an executor that exposes getrawmetatable/setreadonly (for the
    outgoing hook). Incoming translation works without it.
]]

local Players           = game:GetService("Players")
local HttpService       = game:GetService("HttpService")
local TextChatService   = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui        = game:GetService("StarterGui")
local LocalPlayer       = Players.LocalPlayer

local env = (getgenv and getgenv()) or _G

--------------------------------------------------------------------------
-- State (kept across re-executions so the hook is only installed once)
--------------------------------------------------------------------------
local state = env.__ChatTranslatorState or {
    outEnabled = false,
    outLang    = "en",
    inEnabled  = true,
    inLang     = "en",
    hooked     = false,
}
env.__ChatTranslatorState = state

--------------------------------------------------------------------------
-- HTTP
--------------------------------------------------------------------------
local requestFn = (syn and syn.request) or (http and http.request) or http_request or request

local function httpGet(url)
    if requestFn then
        local ok, res = pcall(requestFn, { Url = url, Method = "GET" })
        if ok and type(res) == "table" and type(res.Body) == "string" then
            return res.Body
        end
        return nil
    end
    local ok, body = pcall(function()
        return game:HttpGet(url, true)
    end)
    return ok and body or nil
end

--------------------------------------------------------------------------
-- Translation
--------------------------------------------------------------------------
local cache = {}

-- Returns translatedText, detectedSourceLang  (or nil on failure)
local function translate(text, target)
    local key = target .. "\0" .. text
    local hit = cache[key]
    if hit then return hit[1], hit[2] end

    local url = string.format(
        "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=%s&dt=t&q=%s",
        HttpService:UrlEncode(target),
        HttpService:UrlEncode(text)
    )

    local body = httpGet(url)
    if not body then return nil end

    local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
    if not ok or type(data) ~= "table" or type(data[1]) ~= "table" then return nil end

    -- data[1] is a LIST of sentence chunks. The original script only read
    -- chunk 1, which truncated anything longer than one sentence.
    local parts = {}
    for _, chunk in ipairs(data[1]) do
        if type(chunk) == "table" and type(chunk[1]) == "string" then
            parts[#parts + 1] = chunk[1]
        end
    end
    if #parts == 0 then return nil end

    local out = table.concat(parts)
    local detected = (type(data[3]) == "string" and data[3])
                  or (type(data[2]) == "string" and data[2])
                  or "auto"

    cache[key] = { out, detected }
    return out, detected
end

--------------------------------------------------------------------------
-- Chat plumbing
--------------------------------------------------------------------------
local usingTextChatService = TextChatService.ChatVersion == Enum.ChatVersion.TextChatService

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

local function getLegacyRemote()
    local events = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
    local remote = events and events:FindFirstChild("SayMessageRequest")
                or ReplicatedStorage:FindFirstChild("SayMessageRequest", true)
    if remote and remote:IsA("RemoteEvent") then return remote end
    return nil
end

-- DisplaySystemMessage parses rich text, so player-authored text must be escaped
local function escapeRich(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function feed(text)
    local channel = getChannel()
    if channel then
        local ok = pcall(function()
            channel:DisplaySystemMessage(
                "<font color=\"#00FFCC\">[Translator] " .. escapeRich(text) .. "</font>"
            )
        end)
        if ok then return end
    end
    pcall(function()
        StarterGui:SetCore("ChatMakeSystemMessage", {
            Text  = "[Translator] " .. text,
            Color = Color3.fromRGB(0, 255, 204),
            Font  = Enum.Font.SourceSansBold,
        })
    end)
end

-- Messages we generated ourselves, so the outgoing hook lets them through.
local passthrough = {}

local function sendToServer(text)
    passthrough[text] = true
    task.defer(function() passthrough[text] = nil end)

    local channel = usingTextChatService and getChannel()
    if channel then
        pcall(function() channel:SendAsync(text) end)
        return
    end
    local remote = getLegacyRemote()
    if remote then
        pcall(function() remote:FireServer(text, "All") end)
    end
end

--------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------
local function status()
    feed(string.format(
        "outgoing: %s (%s)  |  incoming: %s (%s)",
        state.outEnabled and "ON" or "OFF", state.outLang:upper(),
        state.inEnabled  and "ON" or "OFF", state.inLang:upper()
    ))
end

-- Returns true if the text was a command and must NOT be sent to the server.
local function handleCommand(text)
    local lower = text:lower():match("^%s*(.-)%s*$")

    if lower == ">d" or lower == ">off" then
        state.outEnabled = false
        feed("Outgoing translation OFF. Raw messages restored.")
        return true
    end

    if lower == ">tr" then
        status()
        return true
    end

    if lower == ">help" then
        feed(">xx = outgoing lang | >d = outgoing off | >in xx / >in off | >tr = status")
        return true
    end

    local incoming = lower:match("^>in%s+([%a%-]+)$")
    if incoming then
        if incoming == "off" then
            state.inEnabled = false
            feed("Incoming translation OFF.")
        else
            state.inLang   = incoming
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

--------------------------------------------------------------------------
-- Outgoing interception
--------------------------------------------------------------------------
-- Returns true when the original call must be swallowed.
local function handleOutgoing(text)
    if type(text) ~= "string" or text == "" then return false end
    if passthrough[text] then return false end
    if handleCommand(text) then return true end
    if not state.outEnabled then return false end
    if text:sub(1, 1) == "/" then return false end -- /e dance, /w, etc.

    task.spawn(function()
        local translated = translate(text, state.outLang)
        sendToServer(translated or text)
        if not translated then
            feed("Translation failed - sent original.")
        end
    end)
    return true
end

-- Games often ship a custom chat UI that sends through its own RemoteEvent
-- rather than the stock SayMessageRequest, so match on shape, not one name.
local function looksLikeChatRemote(inst)
    local ok, lower = pcall(function() return inst.Name:lower() end)
    if not ok then return false end
    return (lower:find("chat") or lower:find("say") or lower:find("message")
         or lower:find("talk") or lower:find("speak")) ~= nil
end

if not state.hooked then
    local canHook = getrawmetatable and setreadonly and getnamecallmethod
    if canHook then
        local mt = getrawmetatable(game)
        local oldNamecall = mt.__namecall
        local wrap = newcclosure or function(f) return f end

        setreadonly(mt, false)
        mt.__namecall = wrap(function(self, ...)
            local method = getnamecallmethod()

            if method == "SendAsync" or method == "FireServer" then
                local ok, isInstance = pcall(function() return typeof(self) == "Instance" end)
                if ok and isInstance then
                    local isChatSend =
                        (method == "SendAsync" and self:IsA("TextChannel")) or
                        (method == "FireServer" and looksLikeChatRemote(self))

                    if isChatSend and handleOutgoing((...)) then
                        return nil
                    end
                end
            end

            return oldNamecall(self, ...)
        end)
        setreadonly(mt, true)
        state.hooked = true
    end
end

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

if usingTextChatService then
    TextChatService.OnIncomingMessage = function(message)
        -- This callback must never yield, so all work goes to a new thread.
        if not state.inEnabled then return end

        local source = message.TextSource
        if not source then return end                        -- system message
        if source.UserId == LocalPlayer.UserId then return end

        local text = message.Text
        if not text or text == "" then return end
        if seen[message.MessageId] then return end
        seen[message.MessageId] = true

        local player = Players:GetPlayerByUserId(source.UserId)
        local name = player and player.DisplayName or "?"

        task.spawn(showIncoming, name, text, state.inLang)
        return nil
    end
else
    local events = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
    local onFiltered = events and events:FindFirstChild("OnMessageDoneFiltering")
    if onFiltered and onFiltered:IsA("RemoteEvent") then
        onFiltered.OnClientEvent:Connect(function(data)
            if not state.inEnabled then return end
            if type(data) ~= "table" then return end
            if not data.Message or data.Message == "" then return end
            if data.FromSpeaker == LocalPlayer.Name then return end
            task.spawn(showIncoming, data.FromSpeaker or "?", data.Message, state.inLang)
        end)
    end
end

--------------------------------------------------------------------------
feed("Loaded. Try '>ja' to translate what you send, '>in en' for what you read.")
if not state.hooked then
    feed("WARNING: no getrawmetatable - outgoing translation is unavailable in this executor.")
end
status()
