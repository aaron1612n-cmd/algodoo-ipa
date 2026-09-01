--[[
    Chat Send Diagnostic (v2)
    -------------------------
    Prints a short plain-text verdict answering one question: can an executor
    hook see this game's chat send, and does SendAsync still work for sending?

    Run it, type "zzdiag hello", and wait for the VERDICT line.
]]

local Players         = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local StarterGui      = game:GetService("StarterGui")

local PROBE  = "zzdiag"
local report = {}
local busy   = false
local matched = nil

local function findChannel()
    local channels = TextChatService:FindFirstChild("TextChannels")
    if not channels then return nil end
    local general = channels:FindFirstChild("RBXGeneral")
    if general then return general end
    for _, ch in ipairs(channels:GetChildren()) do
        if ch:IsA("TextChannel") then return ch end
    end
    return nil
end

-- Plain text only. This game's chat does not parse rich text and shows the
-- markup literally.
local function out(text)
    report[#report + 1] = text
    local channel = findChannel()
    if channel then
        local ok = pcall(function() channel:DisplaySystemMessage("[D] " .. text) end)
        if ok then return end
    end
    pcall(function()
        StarterGui:SetCore("ChatMakeSystemMessage", {
            Text  = "[D] " .. text,
            Color = Color3.fromRGB(255, 209, 102),
        })
    end)
end

--------------------------------------------------------------------------
-- Environment, condensed to two lines
--------------------------------------------------------------------------
local function yn(v) return v ~= nil and "y" or "n" end

local channelNames = {}
local channels = TextChatService:FindFirstChild("TextChannels")
if channels then
    for _, ch in ipairs(channels:GetChildren()) do
        if ch:IsA("TextChannel") then channelNames[#channelNames + 1] = ch.Name end
    end
end

out("ver=" .. tostring(TextChatService.ChatVersion)
 .. " chans=" .. (#channelNames > 0 and table.concat(channelNames, "/") or "none"))
out("grmt=" .. yn(getrawmetatable) .. " sro=" .. yn(setreadonly)
 .. " gncm=" .. yn(getnamecallmethod) .. " ncc=" .. yn(newcclosure)
 .. " hmm=" .. yn(hookmetamethod) .. " clip=" .. yn(setclipboard))

--------------------------------------------------------------------------
-- Hook + self-test
--------------------------------------------------------------------------
local selfTest = false

if getrawmetatable and setreadonly and getnamecallmethod then
    local mt   = getrawmetatable(game)
    local old  = mt.__namecall
    local wrap = newcclosure or function(f) return f end

    setreadonly(mt, false)
    mt.__namecall = wrap(function(self, ...)
        local method = getnamecallmethod()
        if method == "FindFirstChild" then selfTest = true end

        if not busy and not matched then
            busy = true
            local count = select("#", ...)
            for i = 1, math.min(count, 4) do
                local value = select(i, ...)
                if type(value) == "string" and value:lower():find(PROBE, 1, true) then
                    local name = "?"
                    pcall(function() name = self:GetFullName() end)
                    matched = method .. " on " .. name
                    out("MATCH " .. matched)
                    break
                end
            end
            busy = false
        end

        return old(self, ...)
    end)
    setreadonly(mt, true)

    workspace:FindFirstChild("__diag_probe__")
else
    out("cannot hook: executor missing a global")
end

out("hook fires here: " .. (selfTest and "YES" or "NO"))
out("NOW TYPE:  zzdiag hello")

--------------------------------------------------------------------------
-- Verdict, then test whether SendAsync can still deliver a message
--------------------------------------------------------------------------
task.delay(30, function()
    if matched then
        out("VERDICT: hookable -> " .. matched)
    else
        out("VERDICT: NOT hookable from this VM. Needs custom input box.")
    end

    local channel = findChannel()
    if channel then
        local ok, err = pcall(function() channel:SendAsync("zzsend") end)
        out("SendAsync test: " .. (ok and "no error - did 'zzsend' appear as your message?"
                                      or ("ERROR " .. tostring(err))))
    else
        out("SendAsync test: no TextChannel found")
    end

    if setclipboard then
        pcall(setclipboard, table.concat(report, "\n"))
        out("full report copied to clipboard")
    end
end)
