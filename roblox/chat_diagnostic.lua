--[[
    Chat Send Diagnostic
    --------------------
    Answers one question: when you send a chat message in THIS game, what
    call actually carries it to the server, and can an executor hook see it?

    Run it, then type a message containing  zzdiag  (e.g. "zzdiag hello").
    Read the yellow [DIAG] lines it prints.

        MATCH method=... obj=...   -> a hook CAN see your chat send, and this
                                      names exactly what to intercept.
        no MATCH lines at all      -> the send happens outside this VM
                                      (CoreScript chat); a namecall hook
                                      cannot intercept it on this executor.
]]

local Players         = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local StarterGui      = game:GetService("StarterGui")

local PROBE = "zzdiag"

local report = {}
local busy   = false

local function escapeRich(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

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

local function out(text)
    report[#report + 1] = text
    local channel = findChannel()
    if channel then
        local ok = pcall(function()
            channel:DisplaySystemMessage(
                "<font color=\"#FFD166\">[DIAG] " .. escapeRich(text) .. "</font>"
            )
        end)
        if ok then return end
    end
    pcall(function()
        StarterGui:SetCore("ChatMakeSystemMessage", {
            Text  = "[DIAG] " .. text,
            Color = Color3.fromRGB(255, 209, 102),
        })
    end)
end

--------------------------------------------------------------------------
-- 1. Environment
--------------------------------------------------------------------------
local function yn(v) return v ~= nil and "yes" or "no" end

out("ChatVersion = " .. tostring(TextChatService.ChatVersion))
out("getrawmetatable=" .. yn(getrawmetatable)
 .. " setreadonly=" .. yn(setreadonly)
 .. " getnamecallmethod=" .. yn(getnamecallmethod)
 .. " newcclosure=" .. yn(newcclosure))
out("hookmetamethod=" .. yn(hookmetamethod)
 .. " hookfunction=" .. yn(hookfunction)
 .. " checkcaller=" .. yn(checkcaller)
 .. " setclipboard=" .. yn(setclipboard))

local channels = TextChatService:FindFirstChild("TextChannels")
if channels then
    local names = {}
    for _, ch in ipairs(channels:GetChildren()) do
        names[#names + 1] = ch.Name .. "(" .. ch.ClassName .. ")"
    end
    out("TextChannels: " .. (#names > 0 and table.concat(names, ", ") or "empty"))
else
    out("TextChannels: NONE")
end

--------------------------------------------------------------------------
-- 2. Install probe hook and self-test it
--------------------------------------------------------------------------
local selfTest = false

if getrawmetatable and setreadonly and getnamecallmethod then
    local mt   = getrawmetatable(game)
    local old  = mt.__namecall
    local wrap = newcclosure or function(f) return f end

    setreadonly(mt, false)
    mt.__namecall = wrap(function(self, ...)
        local method = getnamecallmethod()

        if method == "FindFirstChild" then
            selfTest = true
        end

        if not busy then
            busy = true

            -- Any call carrying our probe string in its first few arguments.
            local count = select("#", ...)
            for i = 1, math.min(count, 4) do
                local value = select(i, ...)
                if type(value) == "string" and value:lower():find(PROBE, 1, true) then
                    local name = "?"
                    pcall(function() name = self:GetFullName() end)
                    out("MATCH method=" .. method .. " obj=" .. name .. " arg" .. i .. "=" .. value)
                    break
                end
            end

            -- Chat-shaped remotes, even when the payload is not a plain string.
            if method == "FireServer" or method == "InvokeServer" then
                local ok, lower = pcall(function() return self.Name:lower() end)
                if ok and (lower:find("chat") or lower:find("say")
                        or lower:find("message") or lower:find("talk")
                        or lower:find("speak")) then
                    local name = "?"
                    pcall(function() name = self:GetFullName() end)
                    out("CHAT-REMOTE method=" .. method .. " obj=" .. name)
                end
            end

            busy = false
        end

        return old(self, ...)
    end)
    setreadonly(mt, true)

    workspace:FindFirstChild("__diag_probe__")
else
    out("cannot hook: executor is missing a required global")
end

out("namecall hook fires in this VM: " .. tostring(selfTest))

--------------------------------------------------------------------------
-- 3. Instructions + clipboard dump
--------------------------------------------------------------------------
out("NOW TYPE A MESSAGE CONTAINING: " .. PROBE)

task.delay(45, function()
    local dump = table.concat(report, "\n")
    if setclipboard then
        pcall(setclipboard, dump)
        out("report copied to clipboard (" .. #report .. " lines)")
    else
        out("no setclipboard; screenshot the lines above")
    end
end)
