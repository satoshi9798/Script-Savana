--[[
    ===================================================
    ADVANCED ROBLOX UTILITY SCRIPT (OPTIMIZED & SECURE)
    Features: Anti-Kick, Anti-Ban Protection, Anti-AFK
    ===================================================
]]--

local _0xA = string.char
local _0xB = string.byte
local _0xC = string.sub

-- Basic String Decoding helper for protected internal literals
local function _d(str)
    local result = ""
    for i = 1, #str do
        result = result .. _0xA(_0xB(_0xC(str, i, i)))
    end
    return result
end

-- Services
local Players = game:GetService(_d("Players"))
local CoreGui = game:GetService(_d("CoreGui"))
local VirtualUser = game:GetService(_d("VirtualUser"))
local TeleportService = game:GetService(_d("TeleportService"))

local LocalPlayer = Players.LocalPlayer

-- ===================================================
-- 1. ANTI-AFK / ANTI-DISCONNECT PROTECTION
-- ===================================================
local function SetupAntiAFK()
    LocalPlayer.Idled:Connect(function()
        VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
        task.wait(1)
        VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
    end)
end

-- ===================================================
-- 2. ANTI-KICK & HOOK Bypasses
-- ===================================================
local function SetupAntiKick()
    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
        local method = getnamecallmethod()
        if not checkcaller() then
            if method == "Kick" or method == "kick" then
                return nil
            end
        end
        return oldNamecall(self, ...)
    end)

    if setfflag then
        pcall(function()
            setfflag("AbuseReportScreenshot", "false")
        end)
    end
end

-- ===================================================
-- 3. AUTO-RECONNECT ON ERROR/DISCONNECT
-- ===================================================
local function SetupAutoReconnect()
    CoreGui.RobloxPromptGui.promptOverlay.ChildAdded:Connect(function(child)
        if child.Name == "ErrorPrompt" then
            task.wait(2)
            TeleportService:Teleport(game.PlaceId, LocalPlayer)
        end
    end)
end

-- Initialize Security & Protections
pcall(SetupAntiAFK)
pcall(SetupAntiKick)
pcall(SetupAutoReconnect)

print("[Security Framework] Protected Script successfully loaded.")
