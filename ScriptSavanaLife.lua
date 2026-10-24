local HttpService = game:GetService("HttpService")
local PlayersKey = game:GetService("Players")
local LPKey = PlayersKey.LocalPlayer
local PlayerGuiKey = LPKey:WaitForChild("PlayerGui")

local function SatoshiHiddenString(data)
    local k={83,75,101,121}
    local out={}
    for i=1,#data do out[i]=string.char(bit32.bxor(data[i],k[((i-1)%#k)+1])) end
    return table.concat(out)
end
local FIREBASE_API_KEY = SatoshiHiddenString({18,2,31,24,0,50,33,3,43,59,80,1,97,41,81,27,60,122,86,29,41,3,87,46,7,24,16,24,53,121,14,1,101,5,2,23,58,30,6})
local FIREBASE_PROJECT_ID = SatoshiHiddenString({32,42,17,22,32,35,12,84,32,42,19,24,61,42})

local requestFunc =
    (syn and syn.request)
    or http_request
    or request
    or (http and http.request)

if not requestFunc then
    warn("[SATOSHI] Executor sem suporte a HTTP request.")
    return
end

local function getSatoshiWID()
    local candidates = {
        function() return gethwid and gethwid() end,
        function() return get_hwid and get_hwid() end,
        function()
            if identifyexecutor then
                local a,b = identifyexecutor()
                return nil
            end
        end,
        function()
            local ok, value = pcall(function()
                return game:GetService("RbxAnalyticsService"):GetClientId()
            end)
            return ok and value or nil
        end,
    }
    for _,fn in ipairs(candidates) do
        local ok,value=pcall(fn)
        if ok and type(value)=="string" and #value>=10 then
            return "SATOSHI-"..value
        end
    end
    return nil
end

local SATOSHI_WID = getSatoshiWID()
if not SATOSHI_WID then
    warn("[SATOSHI] Não foi possível obter um identificador persistente deste ambiente.")
    return
end

local function firebaseAuth()
    local response = requestFunc({
        Url = "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=" .. FIREBASE_API_KEY,
        Method = "POST",
        Headers = {["Content-Type"]="application/json"},
        Body = HttpService:JSONEncode({returnSecureToken=true})
    })
    local code=response and (response.StatusCode or response.Status)
    if code~=200 then
        return nil,"Falha ao conectar ao Firebase ("..tostring(code)..")"
    end
    local ok,data=pcall(function() return HttpService:JSONDecode(response.Body) end)
    if not ok or not data.idToken then return nil,"Falha na autenticação" end
    return data.idToken
end

local function keyDocumentUrl(key)
    return "https://firestore.googleapis.com/v1/projects/"..FIREBASE_PROJECT_ID
        .."/databases/(default)/documents/keys/"..HttpService:UrlEncode(key)
end

local function validateOrActivateKey(key)
    key=tostring(key or ""):gsub("^%s+",""):gsub("%s+$","")
    if key=="" then return false,"Digite sua key" end

    local token,authErr=firebaseAuth()
    if not token then return false,authErr end

    local url=keyDocumentUrl(key)
    local response=requestFunc({
        Url=url, Method="GET",
        Headers={["Authorization"]="Bearer "..token}
    })
    local code=response and (response.StatusCode or response.Status)
    if code==404 then return false,"KEY INVÁLIDA" end
    if code~=200 then return false,"Erro ao consultar key ("..tostring(code)..")" end

    local ok,doc=pcall(function() return HttpService:JSONDecode(response.Body) end)
    if not ok then return false,"Resposta inválida do servidor" end
    local f=doc.fields or {}
    local status=f.status and f.status.stringValue or ""
    local wid=f.wid and f.wid.stringValue or ""
    local durationDays=f.durationDays and tonumber(f.durationDays.integerValue) or 0
    local expiresAt=f.expiresAt and f.expiresAt.timestampValue or nil

    if status=="blocked" then return false,"KEY BLOQUEADA" end
    if status=="expired" then return false,"KEY EXPIRADA" end

    if status=="active" then
        if wid~=SATOSHI_WID then return false,"KEY VINCULADA A OUTRO DISPOSITIVO" end
        if expiresAt then
            local y,mo,d,h,mi,se=expiresAt:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
            if y then
                local exp=os.time({year=tonumber(y),month=tonumber(mo),day=tonumber(d),hour=tonumber(h),min=tonumber(mi),sec=tonumber(se)})
                local now=os.time(os.date("!*t"))
                if exp and now>=exp then return false,"KEY EXPIRADA" end
            end
        end
        return true,"ACESSO LIBERADO"
    end

    if status~="unused" or wid~="" or durationDays<=0 then
        return false,"KEY INDISPONÍVEL"
    end

    local now=os.time()
    local expires=now+(durationDays*86400)
    local activatedISO=os.date("!%Y-%m-%dT%H:%M:%SZ",now)
    local expiresISO=os.date("!%Y-%m-%dT%H:%M:%SZ",expires)
    local patchUrl=url
        .."?updateMask.fieldPaths=status"
        .."&updateMask.fieldPaths=wid"
        .."&updateMask.fieldPaths=activatedAt"
        .."&updateMask.fieldPaths=expiresAt"
    local patchBody={fields={
        status={stringValue="active"},
        wid={stringValue=SATOSHI_WID},
        activatedAt={timestampValue=activatedISO},
        expiresAt={timestampValue=expiresISO}
    }}
    local patch=requestFunc({
        Url=patchUrl, Method="PATCH",
        Headers={
            ["Authorization"]="Bearer "..token,
            ["Content-Type"]="application/json"
        },
        Body=HttpService:JSONEncode(patchBody)
    })
    local patchCode=patch and (patch.StatusCode or patch.Status)
    if patchCode~=200 then
        return false,"ATIVAÇÃO RECUSADA ("..tostring(patchCode)..")"
    end
    return true,"KEY ATIVADA - ACESSO LIBERADO"
end

for _,name in ipairs({"SATOSHI_KEY_SYSTEM"}) do
    local old=PlayerGuiKey:FindFirstChild(name) or game:GetService("CoreGui"):FindFirstChild(name)
    if old then old:Destroy() end
end

local keyGui=Instance.new("ScreenGui")
keyGui.Name="SATOSHI_KEY_SYSTEM"; keyGui.ResetOnSpawn=false; keyGui.DisplayOrder=1000000; keyGui.Parent=PlayerGuiKey
local keyFrame=Instance.new("Frame",keyGui)
keyFrame.AnchorPoint=Vector2.new(.5,.5); keyFrame.Position=UDim2.fromScale(.5,.5); keyFrame.Size=UDim2.fromOffset(390,250)
keyFrame.BackgroundColor3=Color3.fromRGB(10,10,15); keyFrame.BorderSizePixel=0; keyFrame.Active=true
Instance.new("UICorner",keyFrame).CornerRadius=UDim.new(0,14)
local keyStroke=Instance.new("UIStroke",keyFrame); keyStroke.Color=Color3.fromRGB(116,72,235); keyStroke.Transparency=.2
local keySize=Instance.new("UISizeConstraint",keyFrame); keySize.MinSize=Vector2.new(300,235); keySize.MaxSize=Vector2.new(430,270)

local keyTitle=Instance.new("TextLabel",keyFrame)
keyTitle.Position=UDim2.new(0,20,0,18); keyTitle.Size=UDim2.new(1,-40,0,30); keyTitle.BackgroundTransparency=1
keyTitle.Text="SATOSHI SCRIPT'S"; keyTitle.TextColor3=Color3.new(1,1,1); keyTitle.Font=Enum.Font.GothamBold; keyTitle.TextSize=22
local keySub=Instance.new("TextLabel",keyFrame)
keySub.Position=UDim2.new(0,20,0,51); keySub.Size=UDim2.new(1,-40,0,20); keySub.BackgroundTransparency=1
keySub.Text="KEY SYSTEM"; keySub.TextColor3=Color3.fromRGB(166,143,255); keySub.Font=Enum.Font.GothamSemibold; keySub.TextSize=12

local SATOSHI_KEY_FILE="SATOSHI_SCRIPTS/saved_key.txt"

local function SatoshiLoadSavedKey()
    if not (isfile and readfile) then return "" end
    local ok,data=pcall(function()
        if isfile(SATOSHI_KEY_FILE) then
            return readfile(SATOSHI_KEY_FILE)
        end
        return ""
    end)
    return ok and tostring(data or "") or ""
end

local function SatoshiSaveKey(value)
    if not writefile then return end
    pcall(function()
        if makefolder and not (isfolder and isfolder("SATOSHI_SCRIPTS")) then
            makefolder("SATOSHI_SCRIPTS")
        end
        writefile(SATOSHI_KEY_FILE,tostring(value or ""))
    end)
end

local keyBox=Instance.new("TextBox",keyFrame)
keyBox.Position=UDim2.new(0,24,0,92); keyBox.Size=UDim2.new(1,-48,0,44); keyBox.BackgroundColor3=Color3.fromRGB(22,21,30)
keyBox.BorderSizePixel=0; keyBox.PlaceholderText="Digite sua key..."; keyBox.Text=SatoshiLoadSavedKey(); keyBox.ClearTextOnFocus=false
keyBox.TextColor3=Color3.new(1,1,1); keyBox.PlaceholderColor3=Color3.fromRGB(120,117,135); keyBox.Font=Enum.Font.GothamMedium; keyBox.TextSize=13
Instance.new("UICorner",keyBox).CornerRadius=UDim.new(0,9)
local boxPad=Instance.new("UIPadding",keyBox); boxPad.PaddingLeft=UDim.new(0,12); boxPad.PaddingRight=UDim.new(0,12)

local verify=Instance.new("TextButton",keyFrame)
verify.Position=UDim2.new(0,24,0,151); verify.Size=UDim2.new(1,-48,0,42); verify.BackgroundColor3=Color3.fromRGB(116,72,235)
verify.BorderSizePixel=0; verify.Text="VERIFICAR KEY"; verify.TextColor3=Color3.new(1,1,1); verify.Font=Enum.Font.GothamBold; verify.TextSize=13
Instance.new("UICorner",verify).CornerRadius=UDim.new(0,9)

local keyStatus=Instance.new("TextLabel",keyFrame)
keyStatus.Position=UDim2.new(0,20,0,205); keyStatus.Size=UDim2.new(1,-40,0,25); keyStatus.BackgroundTransparency=1
keyStatus.Text="Aguardando uma key..."; keyStatus.TextColor3=Color3.fromRGB(150,147,166); keyStatus.Font=Enum.Font.GothamMedium; keyStatus.TextSize=11

local unlocked=false
local busy=false
local function doLogin()
    if busy or unlocked then return end
    busy=true; verify.Text="VERIFICANDO..."; verify.AutoButtonColor=false
    keyStatus.Text="Conectando ao Firebase..."; keyStatus.TextColor3=Color3.fromRGB(190,180,225)
    task.spawn(function()
        local ok,msg=validateOrActivateKey(keyBox.Text)
        if ok then
            unlocked=true
            SatoshiSaveKey(keyBox.Text)
            keyStatus.Text=msg; keyStatus.TextColor3=Color3.fromRGB(100,230,140); verify.Text="LIBERADO ✓"
            task.wait(.65)
            keyGui:Destroy()
        else
            keyStatus.Text=msg; keyStatus.TextColor3=Color3.fromRGB(255,105,105); verify.Text="VERIFICAR KEY"; verify.AutoButtonColor=true; busy=false
        end
    end)
end
verify.MouseButton1Click:Connect(doLogin)
keyBox.FocusLost:Connect(function(enter) if enter then doLogin() end end)
if keyBox.Text~="" then
    task.defer(doLogin)
end

local UISKey=game:GetService("UserInputService")
local draggingKey=false; local dragStartKey; local startPosKey; local dragInputKey
keyFrame.InputBegan:Connect(function(i)
    if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then
        draggingKey=true; dragStartKey=i.Position; startPosKey=keyFrame.Position
    end
end)
keyFrame.InputChanged:Connect(function(i)
    if i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch then dragInputKey=i end
end)
UISKey.InputChanged:Connect(function(i)
    if draggingKey and i==dragInputKey then
        local d=i.Position-dragStartKey
        keyFrame.Position=UDim2.new(startPosKey.X.Scale,startPosKey.X.Offset+d.X,startPosKey.Y.Scale,startPosKey.Y.Offset+d.Y)
    end
end)
UISKey.InputEnded:Connect(function(i)
    if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then draggingKey=false end
end)

while keyGui.Parent and not unlocked do task.wait(.1) end
if not unlocked then return end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local CoreGui = game:GetService("CoreGui")
local VirtualInputManager = game:GetService("VirtualInputManager")
local UIS = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

local LP = Players.LocalPlayer
local PlayerGui = LP:WaitForChild("PlayerGui")

local FLY_SPEED = 55
local FULL_VALUE = 99.5

local ESP_DISTANCE = 500
local ESPEnabled = false
local ShowTracer = false
local ShowHighlight = false

local carcassESPEnabled = false
local CARCASS_ESP_DISTANCE = 500
local carcassESPObjects = {}
local carcassCache = {}

local killAuraEnabled, lastAttack = false, 0
local enableUnderground, disableUnderground
local espObjects = {}

local function getChar()
	return LP.Character or LP.CharacterAdded:Wait()
end

local function getRoot()
	return getChar():WaitForChild("HumanoidRootPart")
end

local Utils = nil
pcall(function()
	Utils = require(
		ReplicatedStorage
			:WaitForChild("AnimalGameFrameworkShared")
			:WaitForChild("Utils")
	)
end)

local canStartText = "nil"
local function uCanStart()
	local ok, result = pcall(function()
		if Utils and Utils.CanEatDrink and Utils.CanEatDrink.CanStart then
			return Utils.CanEatDrink.CanStart(getChar())
		end
		return "Drink"
	end)

	if not ok then
		canStartText = "ERRO"
		return nil
	end

	canStartText = tostring(result)
	return result
end

--============================================================
-- INTERFACE SAVANA HUB
--============================================================

for _,name in ipairs({"SAVANA_MINI_MENU","SAVANA_MINI_MENU_V2","SAVANA_HUB_FINAL","SavanaSpeedTest"}) do
    local old=PlayerGui:FindFirstChild(name) or CoreGui:FindFirstChild(name)
    if old then old:Destroy() end
end

local gui=Instance.new("ScreenGui")
gui.Name="SAVANA_HUB_FINAL"; gui.ResetOnSpawn=false; gui.IgnoreGuiInset=false; gui.DisplayOrder=999999; gui.ZIndexBehavior=Enum.ZIndexBehavior.Sibling; gui.Parent=PlayerGui

local ACCENT=Color3.fromRGB(116,72,235)
local BG=Color3.fromRGB(10,10,15)
local CARD=Color3.fromRGB(22,21,30)
local MUTED=Color3.fromRGB(150,147,166)

local frame=Instance.new("Frame",gui); frame.Name="Main"; frame.AnchorPoint=Vector2.new(.5,.5); frame.Position=UDim2.fromScale(.5,.5); frame.Size=UDim2.fromScale(.66,.66); frame.BackgroundColor3=BG; frame.BackgroundTransparency=.06; frame.BorderSizePixel=0; frame.Active=true
local fs=Instance.new("UISizeConstraint",frame); fs.MinSize=Vector2.new(320,330); fs.MaxSize=Vector2.new(800,520)
Instance.new("UICorner",frame).CornerRadius=UDim.new(0,14)
local stroke=Instance.new("UIStroke",frame); stroke.Color=Color3.fromRGB(72,53,120); stroke.Transparency=.25; stroke.Thickness=1

local sidebar=Instance.new("Frame",frame); sidebar.Size=UDim2.fromScale(.235,1); sidebar.BackgroundColor3=Color3.fromRGB(13,12,19); sidebar.BorderSizePixel=0
Instance.new("UICorner",sidebar).CornerRadius=UDim.new(0,14)
local sideFix=Instance.new("Frame",sidebar); sideFix.Position=UDim2.fromScale(.92,0); sideFix.Size=UDim2.fromScale(.08,1); sideFix.BackgroundColor3=sidebar.BackgroundColor3; sideFix.BorderSizePixel=0

local logo=Instance.new("TextLabel",sidebar); logo.Position=UDim2.fromScale(.08,.035); logo.Size=UDim2.fromScale(.84,.07); logo.BackgroundTransparency=1; logo.Text="SATOSHI SCRIPT'S"; logo.TextColor3=Color3.new(1,1,1); logo.TextXAlignment=Enum.TextXAlignment.Left; logo.Font=Enum.Font.GothamBold; logo.TextScaled=true
local ll=Instance.new("UITextSizeConstraint",logo); ll.MinTextSize=12; ll.MaxTextSize=21
local sublogo=Instance.new("TextLabel",sidebar); sublogo.Position=UDim2.fromScale(.08,.102); sublogo.Size=UDim2.fromScale(.84,.035); sublogo.BackgroundTransparency=1; sublogo.Text="PAINEL DE CONTROLE"; sublogo.TextColor3=MUTED; sublogo.TextXAlignment=Enum.TextXAlignment.Left; sublogo.Font=Enum.Font.GothamMedium; sublogo.TextScaled=true
local sl=Instance.new("UITextSizeConstraint",sublogo); sl.MinTextSize=7; sl.MaxTextSize=10

local content=Instance.new("Frame",frame); content.Position=UDim2.fromScale(.235,0); content.Size=UDim2.fromScale(.765,1); content.BackgroundTransparency=1
local header=Instance.new("Frame",content); header.Size=UDim2.fromScale(1,.105); header.BackgroundTransparency=1; header.Active=true
local pageTitle=Instance.new("TextLabel",header); pageTitle.Position=UDim2.fromScale(.045,.18); pageTitle.Size=UDim2.fromScale(.65,.55); pageTitle.BackgroundTransparency=1; pageTitle.Text="Visuais"; pageTitle.TextColor3=Color3.new(1,1,1); pageTitle.TextXAlignment=Enum.TextXAlignment.Left; pageTitle.Font=Enum.Font.GothamBold; pageTitle.TextScaled=true
local ptl=Instance.new("UITextSizeConstraint",pageTitle); ptl.MinTextSize=13; ptl.MaxTextSize=22
local close=Instance.new("TextButton",header); close.AnchorPoint=Vector2.new(1,.5); close.Position=UDim2.fromScale(.955,.5); close.Size=UDim2.fromOffset(34,34); close.BackgroundColor3=CARD; close.Text="×"; close.TextColor3=Color3.new(1,1,1); close.TextSize=20; close.Font=Enum.Font.GothamBold; close.BorderSizePixel=0
Instance.new("UICorner",close).CornerRadius=UDim.new(0,9)

local pages,tabs={},{ }
local tabInfo={{"Visual","VISUAIS"},{"Combat","COMBATE"},{"Move","JOGADOR"},{"Farm","AUTO FARM"},{"Float","FLUTUANTE"},{"Whitelist","WHITELIST"},{"Profiles","PERFIS"}}
for i,info in ipairs(tabInfo) do
    local key,text=info[1],info[2]
    local b=Instance.new("TextButton",sidebar); b.Position=UDim2.fromScale(.07,.18+(i-1)*.095); b.Size=UDim2.fromScale(.86,.072); b.BackgroundColor3=Color3.fromRGB(24,22,32); b.BackgroundTransparency=.15; b.BorderSizePixel=0; b.Text=text; b.TextColor3=MUTED; b.Font=Enum.Font.GothamSemibold; b.TextScaled=true
    Instance.new("UICorner",b).CornerRadius=UDim.new(0,8); local c=Instance.new("UITextSizeConstraint",b); c.MinTextSize=8;c.MaxTextSize=13
    local p=Instance.new("ScrollingFrame",content); p.Name=key; p.Position=UDim2.fromScale(.035,.11); p.Size=UDim2.fromScale(.93,.84); p.BackgroundTransparency=1; p.BorderSizePixel=0; p.ScrollBarThickness=3; p.ScrollBarImageColor3=ACCENT; p.CanvasSize=UDim2.new(0,0,0,0); p.AutomaticCanvasSize=Enum.AutomaticSize.Y; p.Visible=false
    local layout=Instance.new("UIListLayout",p); layout.Padding=UDim.new(0,7); layout.SortOrder=Enum.SortOrder.LayoutOrder
    local pad=Instance.new("UIPadding",p); pad.PaddingTop=UDim.new(0,3); pad.PaddingBottom=UDim.new(0,12); pad.PaddingLeft=UDim.new(0,3); pad.PaddingRight=UDim.new(0,5)
    pages[key]=p; tabs[key]=b
end

local function openPage(key)
    local names={Visual="Visuais",Combat="Combate",Move="Jogador",Farm="Auto Farm",Float="Flutuante",Whitelist="Whitelist",Profiles="Perfis"}
    pageTitle.Text=names[key] or key
    for k,p in pairs(pages) do p.Visible=(k==key) end
    for k,b in pairs(tabs) do b.BackgroundColor3=(k==key) and ACCENT or Color3.fromRGB(24,22,32); b.TextColor3=(k==key) and Color3.new(1,1,1) or MUTED end
end
for k,b in pairs(tabs) do b.MouseButton1Click:Connect(function() openPage(k) end) end

local function card(parent,title,desc,height)
    local f=Instance.new("Frame",parent); f.Size=UDim2.new(1,-8,0,height or 72); f.BackgroundColor3=CARD; f.BackgroundTransparency=.08; f.BorderSizePixel=0
    Instance.new("UICorner",f).CornerRadius=UDim.new(0,10); local s=Instance.new("UIStroke",f); s.Color=Color3.fromRGB(55,49,72); s.Transparency=.55
    local t=Instance.new("TextLabel",f); t.Position=UDim2.fromOffset(14,10); t.Size=UDim2.new(.68,-10,0,22); t.BackgroundTransparency=1; t.Text=title; t.TextColor3=Color3.fromRGB(245,244,250); t.TextXAlignment=Enum.TextXAlignment.Left; t.Font=Enum.Font.GothamSemibold; t.TextSize=13
    if desc then local d=Instance.new("TextLabel",f); d.Position=UDim2.fromOffset(14,33); d.Size=UDim2.new(.68,-10,0,25); d.BackgroundTransparency=1; d.Text=desc; d.TextColor3=MUTED; d.TextXAlignment=Enum.TextXAlignment.Left; d.TextWrapped=true; d.Font=Enum.Font.Gotham; d.TextSize=10 end
    return f
end

local function toggle(parent,title,desc,initial,callback)
    local f=card(parent,title,desc,70); local state=initial or false
    local b=Instance.new("TextButton",f); b.AnchorPoint=Vector2.new(1,.5); b.Position=UDim2.new(1,-15,.5,0); b.Size=UDim2.fromOffset(48,25); b.BackgroundColor3=state and ACCENT or Color3.fromRGB(55,52,65); b.Text=""; b.BorderSizePixel=0; Instance.new("UICorner",b).CornerRadius=UDim.new(1,0)
    local dot=Instance.new("Frame",b); dot.AnchorPoint=Vector2.new(.5,.5); dot.Position=state and UDim2.fromScale(.74,.5) or UDim2.fromScale(.26,.5); dot.Size=UDim2.fromOffset(19,19); dot.BackgroundColor3=Color3.new(1,1,1); dot.BorderSizePixel=0; Instance.new("UICorner",dot).CornerRadius=UDim.new(1,0)
    local function set(v) state=v; b.BackgroundColor3=v and ACCENT or Color3.fromRGB(55,52,65); dot.Position=v and UDim2.fromScale(.74,.5) or UDim2.fromScale(.26,.5); if callback then callback(v) end end
    b.MouseButton1Click:Connect(function() set(not state) end)
    return f,set,function() return state end
end

local function toggleSlider(parent,title,desc,initial,minv,maxv,sliderInitial,toggleCallback,sliderCallback)
    local f=card(parent,title,desc,112)
    local state=initial or false
    local b=Instance.new("TextButton",f); b.AnchorPoint=Vector2.new(1,0); b.Position=UDim2.new(1,-15,0,13); b.Size=UDim2.fromOffset(48,25); b.BackgroundColor3=state and ACCENT or Color3.fromRGB(55,52,65); b.Text=""; b.BorderSizePixel=0; Instance.new("UICorner",b).CornerRadius=UDim.new(1,0)
    local dot=Instance.new("Frame",b); dot.AnchorPoint=Vector2.new(.5,.5); dot.Position=state and UDim2.fromScale(.74,.5) or UDim2.fromScale(.26,.5); dot.Size=UDim2.fromOffset(19,19); dot.BackgroundColor3=Color3.new(1,1,1); dot.BorderSizePixel=0; Instance.new("UICorner",dot).CornerRadius=UDim.new(1,0)
    local function setToggle(v) state=v; b.BackgroundColor3=v and ACCENT or Color3.fromRGB(55,52,65); dot.Position=v and UDim2.fromScale(.74,.5) or UDim2.fromScale(.26,.5); if toggleCallback then toggleCallback(v) end end
    b.MouseButton1Click:Connect(function() setToggle(not state) end)
    local val=sliderInitial or minv
    local txt=Instance.new("TextLabel",f); txt.AnchorPoint=Vector2.new(1,0); txt.Position=UDim2.new(1,-15,0,67); txt.Size=UDim2.fromOffset(60,18); txt.BackgroundTransparency=1; txt.Text=tostring(val); txt.TextColor3=Color3.fromRGB(211,201,255); txt.TextXAlignment=Enum.TextXAlignment.Right; txt.Font=Enum.Font.GothamBold; txt.TextSize=11
    local bar=Instance.new("Frame",f); bar.Position=UDim2.new(0,14,0,94); bar.Size=UDim2.new(1,-28,0,6); bar.BackgroundColor3=Color3.fromRGB(55,52,65); bar.BorderSizePixel=0; Instance.new("UICorner",bar).CornerRadius=UDim.new(1,0)
    local fill=Instance.new("Frame",bar); fill.BackgroundColor3=ACCENT; fill.BorderSizePixel=0; Instance.new("UICorner",fill).CornerRadius=UDim.new(1,0)
    local knob=Instance.new("Frame",bar); knob.AnchorPoint=Vector2.new(.5,.5); knob.Size=UDim2.fromOffset(15,15); knob.BackgroundColor3=Color3.new(1,1,1); knob.BorderSizePixel=0; Instance.new("UICorner",knob).CornerRadius=UDim.new(1,0)
    local dragging=false
    local function setPercent(p) p=math.clamp(p,0,1); val=math.floor(minv+(maxv-minv)*p+.5); fill.Size=UDim2.fromScale(p,1); knob.Position=UDim2.fromScale(p,.5); txt.Text=tostring(val); if sliderCallback then sliderCallback(val) end end
    local function setX(x) if bar.AbsoluteSize.X>0 then setPercent((x-bar.AbsolutePosition.X)/bar.AbsoluteSize.X) end end
    bar.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging=true;setX(i.Position.X) end end)
    knob.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging=true end end)
    UIS.InputChanged:Connect(function(i) if dragging and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then setX(i.Position.X) end end)
    UIS.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging=false end end)
    task.defer(function() setPercent((val-minv)/(maxv-minv)) end)
    return f,setToggle,function() return state end,function(v) setPercent((v-minv)/(maxv-minv)) end,function() return val end
end

local function action(parent,text,callback)
    local b=Instance.new("TextButton",parent); b.Size=UDim2.new(1,-8,0,52); b.BackgroundColor3=CARD; b.BorderSizePixel=0; b.Text=text; b.TextColor3=Color3.new(1,1,1); b.Font=Enum.Font.GothamSemibold; b.TextSize=13; Instance.new("UICorner",b).CornerRadius=UDim.new(0,10); local s=Instance.new("UIStroke",b);s.Color=Color3.fromRGB(55,49,72);s.Transparency=.55; b.MouseButton1Click:Connect(callback); return b
end

SatoshiWhitelist=SatoshiWhitelist or {}
function SatoshiIsWhitelisted(model)
    if not model then return false end
    local player=Players:GetPlayerFromCharacter(model)
    if not player then
        for _,p in ipairs(Players:GetPlayers()) do
            if p.Character and (model==p.Character or model:IsDescendantOf(p.Character)) then player=p; break end
        end
    end
    return player~=nil and SatoshiWhitelist[player.UserId]==true
end

function SatoshiRefreshWhitelist()
    if not pages.Whitelist then return end
    for _,obj in ipairs(pages.Whitelist:GetChildren()) do
        if obj:GetAttribute("SatoshiWhitelistRow") then obj:Destroy() end
    end
    for _,player in ipairs(Players:GetPlayers()) do
        if player~=LP then
            local row=Instance.new("TextButton",pages.Whitelist)
            row:SetAttribute("SatoshiWhitelistRow",true)
            row.Size=UDim2.new(1,-8,0,58)
            row.BackgroundColor3=SatoshiWhitelist[player.UserId] and Color3.fromRGB(36,100,67) or CARD
            row.BorderSizePixel=0; row.TextColor3=Color3.new(1,1,1); row.Font=Enum.Font.GothamSemibold; row.TextSize=12; row.TextWrapped=true
            row.Text=(SatoshiWhitelist[player.UserId] and "✓ PROTEGIDO  " or "○ LIVRE  ")..player.DisplayName.."  @"..player.Name
            Instance.new("UICorner",row).CornerRadius=UDim.new(0,10)
            local strokeWL=Instance.new("UIStroke",row)
            strokeWL.Color=SatoshiWhitelist[player.UserId] and Color3.fromRGB(80,205,125) or Color3.fromRGB(55,49,72); strokeWL.Transparency=.35
            row.MouseButton1Click:Connect(function()
                SatoshiWhitelist[player.UserId] = not SatoshiWhitelist[player.UserId]
                SatoshiRefreshWhitelist()
            end)
        end
    end
end
task.defer(SatoshiRefreshWhitelist)

SatoshiBinds={Aura=nil,Hitbox=nil,Speed=nil,Subsolo=nil,BeberAgua=nil,AtaqueNormal=nil,AtaqueEspecial=nil,FarmUnificado=nil,ApenasSede=nil}
SatoshiBindWaiting=nil; SatoshiBindActions={}; SatoshiBindButtons={}

function SatoshiAddBind(frame,name,action)
    SatoshiBindActions[name]=action
    local b=Instance.new("TextButton",frame)
    SatoshiBindButtons[name]=b
    b.AnchorPoint=Vector2.new(1,0); b.Position=UDim2.new(1,-70,0,42); b.Size=UDim2.fromOffset(58,22)
    b.BackgroundColor3=Color3.fromRGB(45,41,58); b.Text="BIND"; b.TextColor3=Color3.fromRGB(225,223,235); b.Font=Enum.Font.GothamBold; b.TextSize=9; b.BorderSizePixel=0
    Instance.new("UICorner",b).CornerRadius=UDim.new(0,6)
    b.MouseButton1Click:Connect(function() SatoshiBindWaiting={name=name,button=b}; b.Text="APERTE..." end)
    return b
end

UIS.InputBegan:Connect(function(input,processed)
    if input.KeyCode==Enum.KeyCode.Unknown then return end
    if SatoshiBindWaiting then
        local w=SatoshiBindWaiting
        SatoshiBinds[w.name]=input.KeyCode
        w.button.Text=input.KeyCode.Name
        SatoshiBindWaiting=nil
        return
    end
    if processed or UIS:GetFocusedTextBox() then return end
    for name,key in pairs(SatoshiBinds) do
        if key==input.KeyCode and SatoshiBindActions[name] then
            SatoshiBindActions[name]()
            break
        end
    end
end)

local hitboxEnabled=false; local hitboxRange=50
local specialHitboxEnabled=false; local specialHitboxRange=50
local autoGrabEnabled=false; local autoGrabRange=50
local speedValue=16; local speedEnabled=false
local infiniteStats=false; local sempreDiaEnabled=false

-- SATOSHI FLY
local flyEnabled=false; local flyConnection=nil; local flyAttachment=nil; local flyVelocity=nil
SatoshiFlyCollision={}

function SatoshiSetNoclip(on)
    local char=LP.Character
    if not char then return end
    if on then
        for _,obj in ipairs(char:GetDescendants()) do
            if obj:IsA("BasePart") then
                if SatoshiFlyCollision[obj]==nil then SatoshiFlyCollision[obj]=obj.CanCollide end
                obj.CanCollide=false
            end
        end
    else
        for obj,old in pairs(SatoshiFlyCollision) do
            if obj and obj.Parent then obj.CanCollide=old end
        end
        SatoshiFlyCollision={}
    end
end

function stopFly()
    flyEnabled=false
    if flyConnection then flyConnection:Disconnect(); flyConnection=nil end
    if flyVelocity then flyVelocity:Destroy(); flyVelocity=nil end
    if flyAttachment then flyAttachment:Destroy(); flyAttachment=nil end
    SatoshiSetNoclip(false)
    local char=LP.Character
    if char then
        local hum=char:FindFirstChildOfClass("Humanoid")
        local root=char:FindFirstChild("HumanoidRootPart")
        if hum then hum.AutoRotate=true end
        if root then root.AssemblyLinearVelocity=Vector3.zero; root.AssemblyAngularVelocity=Vector3.zero end
    end
end

function startFly()
    if flyEnabled then return end
    local char=LP.Character
    if not char then return end
    local hum=char:FindFirstChildOfClass("Humanoid")
    local root=char:FindFirstChild("HumanoidRootPart")
    if not hum or not root then return end
    flyEnabled=true; hum.AutoRotate=false; SatoshiSetNoclip(true)
    flyAttachment=Instance.new("Attachment",root); flyAttachment.Name="SatoshiFlyAttachment"
    flyVelocity=Instance.new("LinearVelocity",root); flyVelocity.Name="SatoshiFlyVelocity"
    flyVelocity.Attachment0=flyAttachment; flyVelocity.RelativeTo=Enum.ActuatorRelativeTo.World
    flyVelocity.VelocityConstraintMode=Enum.VelocityConstraintMode.Vector; flyVelocity.MaxForce=math.huge; flyVelocity.VectorVelocity=Vector3.zero
    flyConnection=RunService.RenderStepped:Connect(function()
        if not flyEnabled or not root.Parent then stopFly(); return end
        SatoshiSetNoclip(true)
        local camera=Workspace.CurrentCamera
        if not camera then return end
        local move=hum.MoveDirection
        if move.Magnitude < 0.05 then flyVelocity.VectorVelocity=Vector3.zero; root.AssemblyAngularVelocity=Vector3.zero; return end
        local look=camera.CFrame.LookVector; local right=camera.CFrame.RightVector
        local flatLook=Vector3.new(look.X,0,look.Z).Unit
        local flatRight=Vector3.new(right.X,0,right.Z).Unit
        local direction=(flatLook*move.Dot(flatLook))+(flatRight*move.Dot(flatRight))
        if direction.Magnitude>1 then direction=direction.Unit end
        flyVelocity.VectorVelocity=direction*16
        root.AssemblyAngularVelocity=Vector3.zero
    end)
end

local AntiKickEnabled = false
local originalNamecall = nil

local function setupAntiKick()
    if not hookmetamethod or not getrawmetatable or not newcclosure or not getnamecallmethod then
        warn("[SATOSHI] Executor sem suporte a hookmetamethod para Anti-Kick.")
        return
    end
    local mt = getrawmetatable(game)
    if not mt then return end
    local oldNamecall = mt.__namecall
    originalNamecall = oldNamecall
    setreadonly(mt, false)
    mt.__namecall = newcclosure(function(self, ...)
        local method = getnamecallmethod()
        if AntiKickEnabled and self == LP and (method == "Kick" or method == "kick" or method == "PlayerKick") then
            return warn("[SATOSHI ANTI-KICK] Tentativa de Kick local bloqueada!")
        end
        return oldNamecall(self, ...)
    end)
    setreadonly(mt, true)
end
pcall(setupAntiKick)

_,setESP,getESPState,setESPValue,getESPValue=toggleSlider(pages.Visual,"ESP Players","Nome, animal, vida e distância.",false,0,1500,500,function(v) ESPEnabled=v end,function(v) ESP_DISTANCE=v end)
_,setCarcassESP,getCarcassState,setCarcassValue,getCarcassValue=toggleSlider(pages.Visual,"Carcaças Mortas","Destaca carcaças com o nome exato de quem morreu.",false,0,1000,500,function(v) carcassESPEnabled=v end,function(v) CARCASS_ESP_DISTANCE=v end)
_,setTracer,getTracerState=toggle(pages.Visual,"Linha Rastreadora","Linha até os jogadores visíveis.",false,function(v) ShowTracer=v end)
_,setHighlight,getHighlightState=toggle(pages.Visual,"Contorno","Destaca o personagem conforme a vida.",false,function(v) ShowHighlight=v end)
_,setSempreDia,getSempreDiaState=toggle(pages.Visual,"Sempre Dia","Trava o relógio visual em 12:00.",false,function(v) sempreDiaEnabled=v end)

killAuraButton=Instance.new("TextButton")
auraFrame,setKill,getKillState=toggle(pages.Combat,"Aura de Ataque","Ataca todos os alvos no raio em até 50 studs simultaneamente.",false,function(v) killAuraEnabled=v; lastAttack=0 end)
hitboxFrame,setHitbox,getHitboxState,setHitboxValue,getHitboxValue=toggleSlider(pages.Combat,"Hitbox","Amplia o alcance do ataque manual.",false,0,60,50,function(v) hitboxEnabled=v end,function(v) hitboxRange=v end)
SatoshiAddBind(auraFrame,"Aura",function() setKill(not getKillState()) end)
SatoshiAddBind(hitboxFrame,"Hitbox",function() setHitbox(not getHitboxState()) end)

_,setSpecialHitbox,getSpecialHitboxState,setSpecialHitboxValue,getSpecialHitboxValue=toggleSlider(pages.Combat,"Hitbox Grab / Pounce","Amplia o alcance do ataque especial de agarrar (Tecla F ou Botão Flutuante).",false,0,100,50,function(v) specialHitboxEnabled=v end,function(v) specialHitboxRange=v end)
_,setGrab,getGrabState,setGrabValue,getGrabValue=toggleSlider(pages.Combat,"Auto Grab (30 Studs Acima)","Fica a 30 studs acima do inimigo mantendo a colisão normal.",false,0,150,50,function(v) autoGrabEnabled=v end,function(v) autoGrabRange=v end)

--============================================================
-- LOGICA DO DESAGARRAR AUTOMÁTICO V2 (SINCRONIZADA)
--============================================================
local LatchedPlayersRemote = ReplicatedStorage:WaitForChild("LatchedPlayersNotifyRemoteEvent", 10)
local LatchConfig = nil
pcall(function()
    LatchConfig = require(ReplicatedStorage.AnimalGameSharedCore.LatchEscapeConfig)
end)

getgenv().AUTO_DESGRAB = false
local latchedPlayersList = {}
local escapeThreadInstance = nil

local function stopEscapeThread()
    if escapeThreadInstance then
        task.cancel(escapeThreadInstance)
        escapeThreadInstance = nil
    end
end

local function startEscapeThread()
    stopEscapeThread()
    escapeThreadInstance = task.spawn(function()
        while getgenv().AUTO_DESGRAB and #latchedPlayersList > 0 do
            local char = LP.Character
            if not char then break end

            if not LatchConfig then
                pcall(function()
                    LatchConfig = require(ReplicatedStorage.AnimalGameSharedCore.LatchEscapeConfig)
                end)
            end

            local speed = 1.0
            if LatchConfig and LatchConfig.getRingScaleSpeed then
                speed = LatchConfig.getRingScaleSpeed(char, latchedPlayersList)
            end

            local minScale = (LatchConfig and LatchConfig.MIN_CORRECT_SCALE) or 0.38
            local maxScale = (LatchConfig and LatchConfig.MAX_CORRECT_SCALE) or 0.56
            local maxSize  = (LatchConfig and LatchConfig.MAX_SIZE_SCALE) or 1.05
            local pauseTime = (LatchConfig and LatchConfig.PAUSE_TIME) or 0.5
            local nextPressTime = (LatchConfig and LatchConfig.TIME_BEFORE_NEXT_PRESS_AFTER_PAUSE) or 0.15

            local targetScale = (minScale + maxScale) / 2
            local travel = maxSize - targetScale
            local timeToHit = travel / speed

            task.wait(timeToHit)

            if not getgenv().AUTO_DESGRAB or #latchedPlayersList <= 0 then break end

            if LatchedPlayersRemote then
                LatchedPlayersRemote:FireServer()
            end

            task.wait(pauseTime + nextPressTime + 0.02)
        end
    end)
end

if LatchedPlayersRemote then
    if getgenv().AUTO_DESGRAB_CONNECTION then
        getgenv().AUTO_DESGRAB_CONNECTION:Disconnect()
    end
    getgenv().AUTO_DESGRAB_CONNECTION = LatchedPlayersRemote.OnClientEvent:Connect(function(players)
        if type(players) ~= "table" then return end
        latchedPlayersList = players
        if #players == 0 then
            stopEscapeThread()
            return
        end
        if getgenv().AUTO_DESGRAB then
            startEscapeThread()
        end
    end)
end

_,setDesgrab,getDesgrabState=toggle(pages.Combat,"Desagarrar Automático","Executa automaticamente o minigame de fuga sincronizado.",false,function(v)
    getgenv().AUTO_DESGRAB = v
    if not v then stopEscapeThread() end
end)

speedFrame,setSpeed,getSpeedState,setSpeedValue,getSpeedValue=toggleSlider(pages.Move,"Velocidade","ON/OFF + velocidade + tecla configurável.",false,0,100,16,function(v) speedEnabled=v end,function(v) speedValue=v end)
SatoshiAddBind(speedFrame,"Speed",function() setSpeed(not getSpeedState()) end)
_,setInf,getInfState=toggle(pages.Move,"Stamina + Oxigênio Infinitos","Mantém stamina e oxigênio em 100.",false,function(v) infiniteStats=v end)
_,setFly,getFlyState=toggle(pages.Move,"Fly","Voa seguindo a câmera e o analógico/WASD.",false,function(v) if v then startFly() else stopFly() end end)
undergroundButton=Instance.new("TextButton")
undergroundFrame,setUnder,getUnderState=toggle(pages.Move,"Subsolo","Ativa o modo invisível/subsolo.",false,function(v) if v then enableUnderground() else disableUnderground() end end)
SatoshiAddBind(undergroundFrame,"Subsolo",function() setUnder(not getUnderState()) end)

-- Anti-Kick na aba Jogador
_,setAntiKick,getAntiKickState=toggle(pages.Move,"Anti-Kick","Bloqueia kicks do cliente e previne desconexões por falsos positivos.",false,function(v) AntiKickEnabled=v end)

-- Anti-Queda na aba Jogador
local antiFallEnabled = false
_,setAntiFall,getAntiFallState=toggle(pages.Move,"Anti-Queda","Impede que você tome dano ao pular de penhascos e lugares altos.",false,function(v) antiFallEnabled=v end)

local ALTURA_OFFSET = 1.8
local META_AGUA = 99.5
local LIMIAR_SEDE = 70.0

local META_COMIDA = 99.5
local LIMIAR_FOME = 75.0
local TEMPO_COMENDO_AREA = 8

local autoFarmUnificadoAtivo = false
local apenasSedeAtivo = false
local farmEmExecucao = false

local function obterAlturaAtualAgua(hrpPosition)
    local mainWater = Workspace:FindFirstChild("MainWaterPart")
    local rayOrigin = Vector3.new(hrpPosition.X, hrpPosition.Y + 200, hrpPosition.Z)
    local rayDirection = Vector3.new(0, -600, 0)
    local params = RaycastParams.new()
    params.IgnoreWater = false
    if mainWater then
        params.FilterType = Enum.RaycastFilterType.Include
        params.FilterDescendantsInstances = {mainWater}
    end
    local result = Workspace:Raycast(rayOrigin, rayDirection, params)
    if result then return result.Position.Y
    elseif mainWater then return mainWater.Position.Y + (mainWater.Size.Y / 2) end
    return nil
end

local setApenasSede = nil

local function executarAutoBeberContinuo()
    local character = LP.Character
    if not character or not character:FindFirstChild("HumanoidRootPart") then return end
    local nivelAguaInicial = character:GetAttribute("Water") or 100
    if nivelAguaInicial >= META_AGUA then
        if apenasSedeAtivo and setApenasSede then setApenasSede(false) end
        return
    end

    local hrp = character.HumanoidRootPart
    local alturaAguaAtual = obterAlturaAtualAgua(hrp.Position)
    if alturaAguaAtual then
        local posOriginal = hrp.CFrame
        local posEstrategica = Vector3.new(hrp.Position.X, alturaAguaAtual + ALTURA_OFFSET, hrp.Position.Z)

        local plataforma = Instance.new("Part")
        plataforma.Name = "SatoshiWaterPlatform"
        plataforma.Size = Vector3.new(8, 1, 8)
        plataforma.Position = posEstrategica - Vector3.new(0, 2.5, 0)
        plataforma.Anchored = true
        plataforma.Transparency = 1
        plataforma.CanCollide = true
        plataforma.Parent = Workspace

        hrp.CFrame = CFrame.new(posEstrategica) * (posOriginal - posOriginal.Position)
        hrp.AssemblyLinearVelocity = Vector3.zero
        task.wait(0.8)

        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game)
        task.wait(0.15)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)

        local tempoInicio = os.clock()
        while (autoFarmUnificadoAtivo or apenasSedeAtivo) do
            task.wait(0.5)
            local nivelAguaAtual = character:GetAttribute("Water") or 0
            local tempoDecorrido = os.clock() - tempoInicio
            if nivelAguaAtual >= META_AGUA or tempoDecorrido >= 30 then break end
            if hrp then
                hrp.CFrame = CFrame.new(posEstrategica) * (posOriginal - posOriginal.Position)
                hrp.AssemblyLinearVelocity = Vector3.zero
            end
        end
        plataforma:Destroy()
        if hrp then hrp.CFrame = posOriginal end
    end

    if apenasSedeAtivo and setApenasSede then
        setApenasSede(false)
    end
end

local function obterMaterialAbaixo(posicao)
    local rayOrigin = Vector3.new(posicao.X, posicao.Y + 5, posicao.Z)
    local rayDirection = Vector3.new(0, -15, 0)
    local params = RaycastParams.new()
    params.IgnoreWater = true
    local result = Workspace:Raycast(rayOrigin, rayDirection, params)
    if result then return result.Material, result.Position end
    return nil, nil
end

local function encontrarGramaComivelProxima(posicaoAtual)
    local offsets = {
        Vector3.new(0, 0, 0), Vector3.new(4, 0, 0), Vector3.new(-4, 0, 0),
        Vector3.new(0, 0, 4), Vector3.new(0, 0, -4), Vector3.new(5, 0, 5),
        Vector3.new(-5, 0, -5), Vector3.new(7, 0, 0), Vector3.new(-7, 0, 0),
    }
    for _, offset in ipairs(offsets) do
        local ponto = posicaoAtual + offset
        local mat, pos = obterMaterialAbaixo(ponto)
        if mat == Enum.Material.Grass and pos then return pos end
    end
    return nil
end

local function executarAutoComerGramaComTempo()
    local character = LP.Character
    if not character or not character:FindFirstChild("HumanoidRootPart") then return end
    local nivelComidaInicial = character:GetAttribute("Food") or 100
    if nivelComidaInicial >= META_COMIDA then return end

    local hrp = character.HumanoidRootPart
    local posOriginal = hrp.CFrame
    local tempoInicio = os.clock()

    while autoFarmUnificadoAtivo do
        local nivelComidaAtual = character:GetAttribute("Food") or 0
        local tempoDecorrido = os.clock() - tempoInicio
        if nivelComidaAtual >= META_COMIDA or tempoDecorrido >= 40 then break end

        local pontoGrama = encontrarGramaComivelProxima(hrp.Position)
        if pontoGrama then
            hrp.CFrame = CFrame.new(pontoGrama + Vector3.new(0, 2.5, 0)) * (posOriginal - posOriginal.Position)
            hrp.AssemblyLinearVelocity = Vector3.zero
            task.wait(0.4)

            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game)
            task.wait(0.15)
            VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)

            local espera = 0
            while autoFarmUnificadoAtivo and espera < TEMPO_COMENDO_AREA do
                task.wait(1)
                espera = espera + 1
                if (character:GetAttribute("Food") or 0) >= META_COMIDA then break end
            end
        else
            hrp.CFrame = hrp.CFrame * CFrame.new(3, 0, 0)
            task.wait(0.5)
        end
    end
    if hrp then hrp.CFrame = posOriginal end
end

-- Loop Unificado (Fome e Sede - Automático)
task.spawn(function()
    while true do
        if autoFarmUnificadoAtivo and not farmEmExecucao then
            local character = LP.Character
            if character then
                local agua = character:GetAttribute("Water") or 100
                local comida = character:GetAttribute("Food") or 100

                if agua <= LIMIAR_SEDE then
                    farmEmExecucao = true
                    executarAutoBeberContinuo()
                    farmEmExecucao = false
                elseif comida <= LIMIAR_FOME then
                    farmEmExecucao = true
                    executarAutoComerGramaComTempo()
                    farmEmExecucao = false
                end
            end
        end
        task.wait(2)
    end
end)

-- Opção 1: Farmar Fome e Sede (Com BIND)
local farmUnificadoFrame, setAutoFarm, getAutoFarmState = toggle(pages.Farm, "Farmar Fome e Sede", "Água <= 70% e Fome <= 75%: Enche ambos até 100% de forma ordenada.", false, function(v)
    autoFarmUnificadoAtivo = v
    if not v then farmEmExecucao = false end
end)

SatoshiAddBind(farmUnificadoFrame, "FarmUnificado", function()
    local estadoAtual = getAutoFarmState()
    setAutoFarm(not estadoAtual)
end)

-- Opção 2: Beber Água (Instantâneo / Manual ao ativar, Desativa sozinho ao chegar em 100%)
local apenasSedeFrame, setApenasSedeFunc, getApenasSedeState = toggle(pages.Farm, "Beber Água", "Começa a beber água na hora e desativa automaticamente ao chegar em 100%.", false, function(v)
    apenasSedeAtivo = v
    if v then
        task.spawn(function()
            if not farmEmExecucao then
                farmEmExecucao = true
                executarAutoBeberContinuo()
                farmEmExecucao = false
            end
        end)
    else
        farmEmExecucao = false
    end
end)
setApenasSede = setApenasSedeFunc

SatoshiAddBind(apenasSedeFrame, "ApenasSede", function()
    local estadoAtual = getApenasSedeState()
    setApenasSede(not estadoAtual)
end)

function getHealthColor(hum)
    if not hum or hum.MaxHealth<=0 then return Color3.new(1,1,1) end
    local percent=math.clamp(hum.Health/hum.MaxHealth,0,1)
    return Color3.new(1-percent,percent,0)
end

function removeESP(player)
    local data=espObjects[player]
    if not data then return end
    for _,obj in pairs(data) do pcall(function() if typeof(obj)=="Instance" then obj:Destroy() end end) end
    espObjects[player]=nil
end

function createESP(player)
    if player==LP then return end
    removeESP(player)
    local char=player.Character; if not char then return end
    local root=char:FindFirstChild("HumanoidRootPart"); if not root then return end

    local billboard=Instance.new("BillboardGui",gui); billboard.Name="SAVANA_ESP"; billboard.Adornee=root; billboard.Size=UDim2.fromOffset(300,35); billboard.StudsOffset=Vector3.new(0,4,0); billboard.AlwaysOnTop=true
    local label=Instance.new("TextLabel",billboard); label.Size=UDim2.fromScale(1,1); label.BackgroundTransparency=1; label.TextColor3=Color3.new(0,1,0); label.TextStrokeTransparency=0.35; label.TextStrokeColor3=Color3.new(0,0,0); label.TextSize=11; label.Font=Enum.Font.GothamBold
    local highlight=Instance.new("Highlight",gui); highlight.Name="SAVANA_HIGHLIGHT"; highlight.Adornee=char; highlight.FillColor=Color3.new(0,1,0); highlight.OutlineColor=Color3.new(0,1,0); highlight.FillTransparency=0.82; highlight.OutlineTransparency=0; highlight.DepthMode=Enum.HighlightDepthMode.AlwaysOnTop; highlight.Enabled=ShowHighlight

    local originPart=Instance.new("Part",Workspace); originPart.Name="ESP_TRACER_ORIGIN"; originPart.Size=Vector3.new(0.05,0.05,0.05); originPart.Transparency=1; originPart.Anchored=true; originPart.CanCollide=false
    local originAttachment=Instance.new("Attachment",originPart)
    local targetAttachment=Instance.new("Attachment",root); targetAttachment.Name="SAVANA_TRACER_TARGET"
    local beam=Instance.new("Beam",originPart); beam.Attachment0=originAttachment; beam.Attachment1=targetAttachment; beam.FaceCamera=true; beam.Width0=0.025; beam.Width1=0.025; beam.Color=ColorSequence.new(Color3.new(0,1,0)); beam.Enabled=ShowTracer

    espObjects[player]={Billboard=billboard,Label=label,Highlight=highlight,OriginPart=originPart,TargetAttachment=targetAttachment,Beam=beam}
end

function removeCarcassESP(obj)
    if carcassESPObjects[obj] then
        for _,v in pairs(carcassESPObjects[obj]) do pcall(function() v:Destroy() end) end
        carcassESPObjects[obj]=nil
    end
end

RunService.RenderStepped:Connect(function()
    local camera=Workspace.CurrentCamera
    local myChar=LP.Character; local myRoot=myChar and myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return end

    for _,player in ipairs(Players:GetPlayers()) do
        if player~=LP then
            local char=player.Character; local root=char and char:FindFirstChild("HumanoidRootPart")
            if char and root then
                local data=espObjects[player]
                if not data or not data.Billboard or not data.Billboard.Parent then createESP(player); data=espObjects[player] end
                if data then
                    local distance=(root.Position-myRoot.Position).Magnitude
                    local visible=ESPEnabled and ESP_DISTANCE>0 and distance<=ESP_DISTANCE
                    data.Billboard.Enabled=visible
                    data.Highlight.Enabled=visible and ShowHighlight
                    data.Beam.Enabled=visible and ShowTracer
                    local animal=char:GetAttribute("AnimalName") or char:GetAttribute("AnimalClass") or "?"
                    local hum=char:FindFirstChildOfClass("Humanoid")
                    local hp,maxHp=0,0
                    if hum then hp=math.floor(hum.Health); maxHp=math.floor(hum.MaxHealth) end
                    data.Label.Text=player.DisplayName.." | "..tostring(animal).." | ♥ "..tostring(hp).." / "..tostring(maxHp).." | "..math.floor(distance).."m"
                    local healthColor=getHealthColor(hum)
                    data.Label.TextColor3=healthColor
                    data.Beam.Color=ColorSequence.new(healthColor)
                    data.Highlight.FillColor=healthColor; data.Highlight.OutlineColor=healthColor
                    if data.OriginPart and camera then data.OriginPart.CFrame=camera.CFrame*CFrame.new(0,-2.5,-1) end
                    carcassCache[char] = player.DisplayName
                end
            elseif espObjects[player] then removeESP(player) end
        end
    end

    if not carcassESPEnabled then
        for obj,_ in pairs(carcassESPObjects) do removeCarcassESP(obj) end
        return
    end

    for _, model in ipairs(CollectionService:GetTagged("Animals")) do
        if model ~= myChar and model:IsA("Model") then
            local hum = model:FindFirstChildOfClass("Humanoid")
            local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
            local isDead = (hum and hum.Health <= 0) or not hum or not model.Parent

            if isDead and root then
                local dist = (root.Position - myRoot.Position).Magnitude
                if dist <= CARCASS_ESP_DISTANCE then
                    local data = carcassESPObjects[model]
                    if not data then
                        local cleanName = carcassCache[model] or model.Name
                        local billboard = Instance.new("BillboardGui", gui)
                        billboard.Name = "SATOSHI_CARCASS_ESP"
                        billboard.Adornee = root
                        billboard.Size = UDim2.fromOffset(250, 30)
                        billboard.StudsOffset = Vector3.new(0, 2, 0)
                        billboard.AlwaysOnTop = true

                        local label = Instance.new("TextLabel", billboard)
                        label.Size = UDim2.fromScale(1, 1)
                        label.BackgroundTransparency = 1
                        label.Text = "CARCAÇA: " .. cleanName
                        label.TextColor3 = Color3.fromRGB(255, 90, 90)
                        label.TextStrokeTransparency = 0.3
                        label.TextStrokeColor3 = Color3.new(0, 0, 0)
                        label.Font = Enum.Font.GothamBold
                        label.TextSize = 11

                        carcassESPObjects[model] = {Billboard = billboard, Label = label}
                        data = carcassESPObjects[model]
                    end

                    if data and data.Billboard then
                        data.Billboard.Enabled = true
                    end
                else
                    removeCarcassESP(model)
                end
            else
                removeCarcassESP(model)
            end
        end
    end
end)

Players.PlayerAdded:Connect(function(player) player.CharacterAdded:Connect(function() task.wait(1); createESP(player) end) end)
Players.PlayerRemoving:Connect(removeESP)
for _,player in ipairs(Players:GetPlayers()) do if player~=LP then if player.Character then createESP(player) end player.CharacterAdded:Connect(function() task.wait(1); createESP(player) end) end end

local AttackRemote=ReplicatedStorage:WaitForChild("AttackHandlerRemoteEvent")

local KILL_AURA_COOLDOWN = 0.35
local KILL_AURA_MAX_TARGETS = 3
local lastGlobalAttack = 0

function attackAura()
    local char=LP.Character; if not char then return end
    local myRoot=char:FindFirstChild("HumanoidRootPart"); if not myRoot then return end
    if char:GetAttribute("IsSpawnProtected") or char:GetAttribute("MovementDisabled") or char:GetAttribute("IsBeingCarried") or char:GetAttribute("IsPouncing") then return end
    
    local attackedCount = 0
    for _,model in ipairs(CollectionService:GetTagged("Animals")) do
        if attackedCount >= KILL_AURA_MAX_TARGETS then break end
        
        if model~=char and model:IsA("Model") and not SatoshiIsWhitelisted(model) and not model:GetAttribute("IsPouncing") and not model:GetAttribute("IsSpawnProtected") then
            local hum=model:FindFirstChildOfClass("Humanoid")
            local root=model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
            if hum and hum.Health>0 and root then
                local d=(root.Position-myRoot.Position).Magnitude
                if d<=50 then
                    pcall(function() AttackRemote:FireServer(hum) end)
                    attackedCount = attackedCount + 1
                end
            end
        end
    end
end

killAuraButton.MouseButton1Click:Connect(function() killAuraEnabled=not killAuraEnabled; lastAttack=0 end)
RunService.Heartbeat:Connect(function() 
    if killAuraEnabled and os.clock()-lastAttack>=KILL_AURA_COOLDOWN then 
        lastAttack=os.clock()
        attackAura() 
    end 
end)

RunService.Heartbeat:Connect(function()
    if not autoGrabEnabled then return end
    local char = LP.Character
    local myRoot = char and char:FindFirstChild("HumanoidRootPart")
    if not myRoot then return end

    local bestTargetRoot = nil
    local shortestDistance = autoGrabRange

    for _, model in ipairs(CollectionService:GetTagged("Animals")) do
        if model ~= char and model:IsA("Model") and not SatoshiIsWhitelisted(model) then
            local hum = model:FindFirstChildOfClass("Humanoid")
            local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
            if hum and hum.Health > 0 and root then
                local dist = (root.Position - myRoot.Position).Magnitude
                if dist <= shortestDistance then
                    shortestDistance = dist
                    bestTargetRoot = root
                end
            end
        end
    end

    if bestTargetRoot then
        local targetPos = bestTargetRoot.Position + Vector3.new(0, 30, 0)
        myRoot.CFrame = CFrame.new(targetPos, bestTargetRoot.Position)
        myRoot.AssemblyLinearVelocity = Vector3.zero
        myRoot.AssemblyAngularVelocity = Vector3.zero
    end
end)

local undergroundEnabled=false; local undergroundY=nil; local surfaceY=nil; local undergroundToken=0
disableUnderground=function()
    undergroundEnabled=false; undergroundToken=undergroundToken+1
    local char=LP.Character; local root=char and char:FindFirstChild("HumanoidRootPart")
    local hum=char and char:FindFirstChildOfClass("Humanoid")
    if hum then hum.CameraOffset=Vector3.zero end
    if not flyEnabled then SatoshiSetNoclip(false) end
    if root and surfaceY then 
        root.CFrame = CFrame.new(root.Position.X, surfaceY + 3, root.Position.Z)*(root.CFrame-root.CFrame.Position) 
    end
    surfaceY=nil; undergroundY=nil; undergroundButton.Text="INVISÍVEL / UNDERGROUND: OFF"
end

enableUnderground=function()
    if undergroundEnabled then return end
    undergroundEnabled=true; undergroundToken=undergroundToken+1; local token=undergroundToken
    undergroundButton.Text="INVISÍVEL: PROCURANDO..."
    task.spawn(function()
        local root=getRoot(); local original=root.CFrame; surfaceY=root.Position.Y
        local foundY=nil
        for offset=5,120,5 do
            if not undergroundEnabled or undergroundToken~=token then root.CFrame=original; return end
            root.CFrame=CFrame.new(original.Position.X, surfaceY-offset, original.Position.Z)*(original-original.Position)
            root.AssemblyLinearVelocity=Vector3.zero
            task.wait(0.05)
            local ray = Workspace:Raycast(root.Position + Vector3.new(0, 10, 0), Vector3.new(0, -20, 0))
            if ray and ray.Material ~= Enum.Material.Water then
                foundY = ray.Position.Y - 4
                break
            end
        end
        if not foundY then 
            foundY = surfaceY - 15 
        end
        
        undergroundY=foundY; SatoshiSetNoclip(true)
        local hum=LP.Character:FindFirstChildOfClass("Humanoid")
        if hum then hum.CameraOffset=Vector3.new(0, surfaceY - undergroundY, 0) end
        undergroundButton.Text="INVISÍVEL / UNDERGROUND: ON"
    end)
end
undergroundButton.MouseButton1Click:Connect(function() if undergroundEnabled then disableUnderground() else enableUnderground() end end)

RunService.Heartbeat:Connect(function()
    if not undergroundEnabled or not undergroundY then return end
    local char=LP.Character; local root=char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    SatoshiSetNoclip(true)
    root.AssemblyLinearVelocity=Vector3.zero; root.AssemblyAngularVelocity=Vector3.zero
    local cf=root.CFrame
    if math.abs(root.Position.Y-undergroundY)>0.03 then 
        root.CFrame=CFrame.new(cf.Position.X, undergroundY, cf.Position.Z)*(cf-cf.Position) 
    end
end)

local PounceRemote = ReplicatedStorage:WaitForChild("SpecialAttackRemoteEvent_PounceAttack", 10)
local specialHitboxLast = 0

function fireSpecialHitbox()
    if not specialHitboxEnabled or os.clock() - specialHitboxLast < 0.35 then return end
    local char = LP.Character
    local myRoot = char and char:FindFirstChild("HumanoidRootPart")
    if not myRoot then return end

    for _, animal in ipairs(CollectionService:GetTagged("Animals")) do
        if animal ~= char and animal:IsA("Model") and not SatoshiIsWhitelisted(animal) then
            local hum = animal:FindFirstChildOfClass("Humanoid")
            local root = animal:FindFirstChild("HumanoidRootPart") or animal.PrimaryPart
            local folder = animal:FindFirstChild("RagdollColliderParts")
            local rag = (folder and folder:FindFirstChild("RagdollColliderRootPart")) or root

            if hum and hum.Health > 0 and root and rag then
                local dist = (root.Position - myRoot.Position).Magnitude
                if dist <= specialHitboxRange then
                    specialHitboxLast = os.clock()
                    pcall(function()
                        if PounceRemote then
                            PounceRemote:FireServer(hum, rag)
                        end
                    end)
                    break
                end
            end
        end
    end
end

UIS.InputBegan:Connect(function(input, processed)
    if not processed and input.KeyCode == Enum.KeyCode.F then
        fireSpecialHitbox()
    end
end)

local hitboxLast = 0
function fireHitboxAttack()
    if not hitboxEnabled or os.clock() - hitboxLast < 0.20 then return end
    hitboxLast = os.clock()
    local char = LP.Character
    local myRoot = char and char:FindFirstChild("HumanoidRootPart")
    if not myRoot then return end

    for _, model in ipairs(CollectionService:GetTagged("Animals")) do
        if model ~= char and model:IsA("Model") and not SatoshiIsWhitelisted(model) then
            local hum = model:FindFirstChildOfClass("Humanoid")
            local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
            if hum and hum.Health > 0 and root then
                if (root.Position - myRoot.Position).Magnitude <= hitboxRange then
                    pcall(function() AttackRemote:FireServer(hum) end)
                    break
                end
            end
        end
    end
end

UIS.InputBegan:Connect(function(input, processed)
    if not processed and input.UserInputType == Enum.UserInputType.MouseButton1 then
        fireHitboxAttack()
    end
end)

RunService.Heartbeat:Connect(function()
    local char=LP.Character; if not char then return end
    local hum=char:FindFirstChildOfClass("Humanoid")
    if hum and speedEnabled and speedValue>0 then hum.WalkSpeed=speedValue end
    if infiniteStats then char:SetAttribute("Stamina",100); char:SetAttribute("Oxygen",100) end
    
    -- Lógica do Anti-Queda
    if antiFallEnabled then
        local root = char:FindFirstChild("HumanoidRootPart")
        if root and hum and hum.Health > 0 then
            local vel = root.AssemblyLinearVelocity
            if vel.Y < -25 then 
                root.AssemblyLinearVelocity = Vector3.new(vel.X, -25, vel.Z)
                
                local rayParams = RaycastParams.new()
                rayParams.FilterDescendantsInstances = {char}
                rayParams.FilterType = Enum.RaycastFilterType.Exclude
                local ray = Workspace:Raycast(root.Position, Vector3.new(0, -12, 0), rayParams)
                if ray and ray.Distance < 8 then
                    root.AssemblyLinearVelocity = Vector3.new(vel.X, 0, vel.Z)
                end
            end
        end
    end
end)
RunService.RenderStepped:Connect(function() if sempreDiaEnabled then Lighting.ClockTime=12 end end)

SatoshiFloatGui=Instance.new("ScreenGui")
SatoshiFloatGui.Name="SatoshiFloatingControls"
SatoshiFloatGui.ResetOnSpawn=false
SatoshiFloatGui.IgnoreGuiInset=false
SatoshiFloatGui.DisplayOrder=26
SatoshiFloatGui.Parent=PlayerGui

SatoshiFloatButtons={}
SatoshiFloatEnabled={}

function SatoshiMakeDraggable(frame)
    local dragging=false
    local dragInput=nil
    local dragStart=nil
    local startPos=nil

    frame.InputBegan:Connect(function(input)
        if input.UserInputType==Enum.UserInputType.Touch or input.UserInputType==Enum.UserInputType.MouseButton1 then
            dragging=true
            dragStart=input.Position
            startPos=frame.Position
            input.Changed:Connect(function()
                if input.UserInputState==Enum.UserInputState.End then dragging=false end
            end)
        end
    end)

    frame.InputChanged:Connect(function(input)
        if input.UserInputType==Enum.UserInputType.Touch or input.UserInputType==Enum.UserInputType.MouseMovement then
            dragInput=input
        end
    end)

    UIS.InputChanged:Connect(function(input)
        if dragging and input==dragInput then
            local delta=input.Position-dragStart
            frame.Position=UDim2.new(startPos.X.Scale,startPos.X.Offset+delta.X,startPos.Y.Scale,startPos.Y.Offset+delta.Y)
        end
    end)
end

SatoshiFloatDefs={
    Aura={title="AUTO ATAQUE",getter=getKillState,setter=setKill},
    Hitbox={title="HITBOX",getter=getHitboxState,setter=setHitbox},
    SpecialHitbox={title="HITBOX GRAB",getter=getSpecialHitboxState,setter=function(v) setSpecialHitboxValue(v and 50 or 0); fireSpecialHitbox() end},
    Grab={title="AUTO AGARRAR",getter=getGrabState,setter=setGrab},
    Water={title="BEBER ÁGUA",getter=getApenasSedeState,setter=setApenasSede},
    Underground={title="SUBSOLO",getter=getUnderState,setter=setUnder},
}

function SatoshiRefreshFloat(name)
    local def=SatoshiFloatDefs[name]
    local obj=SatoshiFloatButtons[name]
    if not def or not obj then return end
    local on=false
    pcall(function() on=def.getter() end)
    obj.Toggle.BackgroundColor3=on and ACCENT or Color3.fromRGB(55,52,68)
    obj.Knob.Position=on and UDim2.new(1,-22,0.5,-8) or UDim2.new(0,4,0.5,-8)
end

function SatoshiCreateFloat(name,index)
    if SatoshiFloatButtons[name] then
        SatoshiFloatButtons[name].Frame.Visible=true
        return
    end
    local def=SatoshiFloatDefs[name]
    if not def then return end

    local f=Instance.new("Frame",SatoshiFloatGui)
    f.Name="Float_"..name
    f.Size=UDim2.fromOffset(150,44)
    f.Position=UDim2.new(1,-170,0,80+(index-1)*52)
    f.BackgroundColor3=Color3.fromRGB(18,17,25)
    f.BackgroundTransparency=.08
    f.BorderSizePixel=0
    f.Active=true
    Instance.new("UICorner",f).CornerRadius=UDim.new(0,10)

    local title=Instance.new("TextLabel",f)
    title.BackgroundTransparency=1
    title.Position=UDim2.fromOffset(10,0)
    title.Size=UDim2.new(1,-60,1,0)
    title.Text=def.title
    title.TextColor3=Color3.new(1,1,1)
    title.Font=Enum.Font.GothamBold
    title.TextSize=10
    title.TextXAlignment=Enum.TextXAlignment.Left

    local toggleBtn=Instance.new("TextButton",f)
    toggleBtn.Name="Toggle"
    toggleBtn.AnchorPoint=Vector2.new(1,.5)
    toggleBtn.Position=UDim2.new(1,-8,.5,0)
    toggleBtn.Size=UDim2.fromOffset(42,24)
    toggleBtn.Text=""
    toggleBtn.BorderSizePixel=0
    Instance.new("UICorner",toggleBtn).CornerRadius=UDim.new(1,0)

    local knob=Instance.new("Frame",toggleBtn)
    knob.Name="Knob"
    knob.Size=UDim2.fromOffset(16,16)
    knob.AnchorPoint=Vector2.new(0,.5)
    knob.BackgroundColor3=Color3.new(1,1,1)
    knob.BorderSizePixel=0
    Instance.new("UICorner",knob).CornerRadius=UDim.new(1,0)

    SatoshiFloatButtons[name]={Frame=f,Toggle=toggleBtn,Knob=knob}
    SatoshiMakeDraggable(f)

    toggleBtn.MouseButton1Click:Connect(function()
        local current=false
        pcall(function() current=def.getter() end)
        def.setter(not current)
        task.defer(function() SatoshiRefreshFloat(name) end)
    end)

    SatoshiRefreshFloat(name)
end

function SatoshiSetFloat(name,on,index)
    SatoshiFloatEnabled[name]=on
    if on then
        SatoshiCreateFloat(name,index)
    elseif SatoshiFloatButtons[name] then
        SatoshiFloatButtons[name].Frame.Visible=false
    end
end

task.spawn(function()
    while gui.Parent do
        for name,on in pairs(SatoshiFloatEnabled) do
            if on then SatoshiRefreshFloat(name) end
        end
        task.wait(.15)
    end
end)

floatOrder={"Aura","Hitbox","SpecialHitbox","Grab","Water","Underground"}
floatLabels={
    Aura="Auto Ataque",
    Hitbox="Hitbox Normal",
    SpecialHitbox="Hitbox Grab",
    Grab="Auto Agarrar",
    Water="Beber Água",
    Underground="Subsolo"
}
for i,name in ipairs(floatOrder) do
    local n=name
    local idx=i
    toggle(
        pages.Float,
        floatLabels[n],
        "Mostra uma caixinha ON/OFF arrastável na tela.",
        false,
        function(v) SatoshiSetFloat(n,v,idx) end
    )
end

SatoshiProfileFolder="SATOSHI_SCRIPTS/profiles"

function SatoshiEnsureProfileFolder()
    if makefolder then
        pcall(function()
            if isfolder and not isfolder("SATOSHI_SCRIPTS") then makefolder("SATOSHI_SCRIPTS") end
            if isfolder and not isfolder(SatoshiProfileFolder) then makefolder(SatoshiProfileFolder) end
        end)
    end
end

function SatoshiSafeProfileName(name)
    name=tostring(name or ""):gsub("^%s+",""):gsub("%s+$","")
    name=name:gsub("[^%w_%-%s]","")
    if name=="" then name="Principal" end
    return name
end

function SatoshiProfilePath(name)
    return SatoshiProfileFolder.."/"..SatoshiSafeProfileName(name)..".json"
end

function SatoshiSerializeBinds()
    local out={}
    for name,key in pairs(SatoshiBinds) do
        if typeof(key)=="EnumItem" then out[name]=key.Name end
    end
    return out
end

function SatoshiCaptureProfile()
    return {
        toggles={
            ESP=getESPState(), Carcass=getCarcassState(),
            Tracer=getTracerState(), Highlight=getHighlightState(),
            SempreDia=getSempreDiaState(),
            Aura=getKillState(), Hitbox=getHitboxState(),
            SpecialHitbox=getSpecialHitboxState(),
            Grab=getGrabState(), Desgrab=getDesgrabState(),
            Speed=getSpeedState(), Inf=getInfState(), Fly=getFlyState(),
            Subsolo=getUnderState(), AntiKick=getAntiKickState(),
            AntiFall=getAntiFallState(),
            AutoFarm=getAutoFarmState(), ApenasSede=getApenasSedeState()
        },
        sliders={
            ESP=getESPValue(), Carcass=getCarcassValue(),
            Hitbox=getHitboxValue(), SpecialHitbox=getSpecialHitboxValue(), Grab=getGrabValue(),
            Speed=getSpeedValue()
        },
        binds=SatoshiSerializeBinds()
    }
end

function SatoshiApplyProfile(data)
    if type(data)~="table" then return false end
    local sl=data.sliders or {}
    local tg=data.toggles or {}

    if sl.ESP~=nil then setESPValue(sl.ESP) end
    if sl.Carcass~=nil then setCarcassValue(sl.Carcass) end
    if sl.Hitbox~=nil then setHitboxValue(sl.Hitbox) end
    if sl.SpecialHitbox~=nil then setSpecialHitboxValue(sl.SpecialHitbox) end
    if sl.Grab~=nil then setGrabValue(sl.Grab) end
    if sl.Speed~=nil then setSpeedValue(sl.Speed) end

    if tg.ESP~=nil then setESP(tg.ESP) end
    if tg.Carcass~=nil then setCarcassESP(tg.Carcass) end
    if tg.Tracer~=nil then setTracer(tg.Tracer) end
    if tg.Highlight~=nil then setHighlight(tg.Highlight) end
    if tg.SempreDia~=nil then setSempreDia(tg.SempreDia) end
    if tg.Hitbox~=nil then setHitbox(tg.Hitbox) end
    if tg.SpecialHitbox~=nil then setSpecialHitboxValue(tg.SpecialHitbox) end
    if tg.Aura~=nil then setKill(tg.Aura) end
    if tg.Grab~=nil then setGrab(tg.Grab) end
    if tg.Desgrab~=nil then setDesgrab(tg.Desgrab) end
    if tg.Speed~=nil then setSpeed(tg.Speed) end
    if tg.Inf~=nil then setInf(tg.Inf) end
    if tg.Fly~=nil then setFly(tg.Fly) end
    if tg.Subsolo~=nil then setUnder(tg.Subsolo) end
    if tg.AntiKick~=nil then setAntiKick(tg.AntiKick) end
    if tg.AntiFall~=nil then setAntiFall(tg.AntiFall) end 
    if tg.AutoFarm~=nil then setAutoFarm(tg.AutoFarm) end
    if tg.ApenasSede~=nil then setApenasSede(tg.ApenasSede) end

    if type(data.binds)=="table" then
        for name,keyName in pairs(data.binds) do
            local kc=Enum.KeyCode[tostring(keyName)]
            if kc then
                SatoshiBinds[name]=kc
                local btn=SatoshiBindButtons and SatoshiBindButtons[name]
                if btn then btn.Text=kc.Name end
            end
        end
    end
    return true
end

profileCard=card(pages.Profiles,"Salvar configurações","Salva suas opções, valores e binds em um perfil.",116)
profileName=Instance.new("TextBox",profileCard)
profileName.Position=UDim2.new(0,14,0,62)
profileName.Size=UDim2.new(1,-28,0,36)
profileName.BackgroundColor3=Color3.fromRGB(35,32,47)
profileName.BorderSizePixel=0
profileName.PlaceholderText="Nome do perfil..."
profileName.Text="Principal"
profileName.ClearTextOnFocus=false
profileName.TextColor3=Color3.new(1,1,1)
profileName.PlaceholderColor3=MUTED
profileName.Font=Enum.Font.GothamMedium
profileName.TextSize=12
Instance.new("UICorner",profileName).CornerRadius=UDim.new(0,8)

profileStatus=Instance.new("TextLabel",pages.Profiles)
profileStatus.Size=UDim2.new(1,-8,0,30)
profileStatus.BackgroundTransparency=1
profileStatus.Text="Digite um nome e salve."
profileStatus.TextColor3=MUTED
profileStatus.Font=Enum.Font.GothamMedium
profileStatus.TextSize=11

action(pages.Profiles,"💾 SALVAR PERFIL",function()
    if not (writefile and HttpService) then
        profileStatus.Text="Executor sem suporte a writefile."
        return
    end
    SatoshiEnsureProfileFolder()
    local name=SatoshiSafeProfileName(profileName.Text)
    local ok,err=pcall(function()
        writefile(SatoshiProfilePath(name),HttpService:JSONEncode(SatoshiCaptureProfile()))
    end)
    profileStatus.Text=ok and ("Perfil salvo: "..name) or ("Erro ao salvar: "..tostring(err))
end)

action(pages.Profiles,"📂 CARREGAR PERFIL",function()
    if not (isfile and readfile and HttpService) then
        profileStatus.Text="Executor sem suporte a readfile."
        return
    end
    local name=SatoshiSafeProfileName(profileName.Text)
    local path=SatoshiProfilePath(name)
    if not isfile(path) then
        profileStatus.Text="Perfil não encontrado: "..name
        return
    end
    local ok,err=pcall(function()
        local data=HttpService:JSONDecode(readfile(path))
        SatoshiApplyProfile(data)
    end)
    profileStatus.Text=ok and ("Perfil carregado: "..name) or ("Erro ao carregar: "..tostring(err))
end)

action(pages.Profiles,"🗑 EXCLUIR PERFIL",function()
    if not (isfile and delfile) then
        profileStatus.Text="Executor sem suporte a excluir arquivo."
        return
    end
    local name=SatoshiSafeProfileName(profileName.Text)
    local path=SatoshiProfilePath(name)
    if isfile(path) then
        pcall(function() delfile(path) end)
        profileStatus.Text="Perfil excluído: "..name
    else
        profileStatus.Text="Perfil não encontrado: "..name
    end
end)

-- Arrastar janela e fechar
bubble=Instance.new("TextButton",gui); bubble.AnchorPoint=Vector2.new(.5,.5); bubble.Position=UDim2.fromScale(.075,.55); bubble.Size=UDim2.fromOffset(52,52); bubble.BackgroundColor3=Color3.fromRGB(25,22,35); bubble.Text="🦁"; bubble.TextScaled=true; bubble.Visible=false; bubble.Active=true; bubble.BorderSizePixel=0; Instance.new("UICorner",bubble).CornerRadius=UDim.new(1,0)
menuOpen=true
function setMenu(v) menuOpen=v; frame.Visible=v; bubble.Visible=not v end
close.MouseButton1Click:Connect(function() setMenu(false) end)
UIS.InputBegan:Connect(function(input,gp) if not gp and input.KeyCode==Enum.KeyCode.RightShift then setMenu(not menuOpen) end end)
makeDraggable=function(handle,target,onTap)
    local dragging,moved=false,false; local start,pos,current
    handle.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging=true; moved=false; start=i.Position; pos=target.Position end end)
    handle.InputChanged:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch then current=i end end)
    UIS.InputChanged:Connect(function(i) if dragging and i==current and Workspace.CurrentCamera then local d=i.Position-start; if d.Magnitude>6 then moved=true end; local vp=Workspace.CurrentCamera.ViewportSize; target.Position=UDim2.fromScale(pos.X.Scale+d.X/vp.X,pos.Y.Scale+d.Y/vp.Y) end end)
    UIS.InputEnded:Connect(function(i) if dragging and (i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch) then dragging=false; if onTap and not moved then onTap() end end end)
end
makeDraggable(header,frame); makeDraggable(bubble,bubble,function() setMenu(true) end); openPage("Visual")

profileLabel=Instance.new("TextLabel",sidebar); profileLabel.AnchorPoint=Vector2.new(0,1); profileLabel.Position=UDim2.fromScale(.08,.965); profileLabel.Size=UDim2.fromScale(.84,.09); profileLabel.BackgroundTransparency=1; profileLabel.Text=LP.DisplayName.."\n@"..LP.Name; profileLabel.TextColor3=Color3.fromRGB(225,223,235); profileLabel.TextXAlignment=Enum.TextXAlignment.Left; profileLabel.TextYAlignment=Enum.TextYAlignment.Center; profileLabel.Font=Enum.Font.GothamMedium; profileLabel.TextSize=10
print("[SATOSHI HUB] Carregado com sucesso!")
