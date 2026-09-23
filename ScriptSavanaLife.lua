--============================================================
-- SATOSHI KEY SYSTEM - FIREBASE
-- Login obrigatório antes de carregar o painel principal
--============================================================

local HttpService = game:GetService("HttpService")
local PlayersKey = game:GetService("Players")
local LPKey = PlayersKey.LocalPlayer
local PlayerGuiKey = LPKey:WaitForChild("PlayerGui")

local FIREBASE_API_KEY = "AIzaSyDzxp5x2b4bo13dzH2WTSuaf2kx6NgniUc"
local FIREBASE_PROJECT_ID = "satoshi-savana"

local requestFunc =
    (syn and syn.request)
    or http_request
    or request
    or (http and http.request)

if not requestFunc then
    warn("[SATOSHI] Executor sem suporte a HTTP request.")
    return
end

-- WID pseudônimo/persistente: tenta usar um identificador oferecido pelo ambiente.
-- Não coleta IMEI, MAC ou serial físico.
local function getSatoshiWID()
    local candidates = {
        function() return gethwid and gethwid() end,
        function() return get_hwid and get_hwid() end,
        function()
            if identifyexecutor then
                local a,b = identifyexecutor()
                -- fallback NÃO é suficiente sozinho para diferenciar dispositivos,
                -- então só é usado junto com ClientId abaixo.
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
        -- Pode ter ocorrido corrida: outra instalação ativou entre GET e PATCH.
        return false,"ATIVAÇÃO RECUSADA ("..tostring(patchCode)..")"
    end
    return true,"KEY ATIVADA - ACESSO LIBERADO"
end

--============================================================
-- TELA DE LOGIN
--============================================================
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

local keyBox=Instance.new("TextBox",keyFrame)
keyBox.Position=UDim2.new(0,24,0,92); keyBox.Size=UDim2.new(1,-48,0,44); keyBox.BackgroundColor3=Color3.fromRGB(22,21,30)
keyBox.BorderSizePixel=0; keyBox.PlaceholderText="Digite sua key..."; keyBox.Text=""; keyBox.ClearTextOnFocus=false
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

-- Arrastar login pelo topo
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

-- O código do painel só continua depois da validação.
while keyGui.Parent and not unlocked do task.wait(.1) end
if not unlocked then return end

--============================================================
-- FIM DO KEY SYSTEM / INÍCIO DO PAINEL ORIGINAL
--============================================================

--============================================================
-- SAVANA MINI MENU V2
-- ESP + AUTO FARM
--
-- ESP:
-- Nome | Animal | HP | Distância
-- Texto muda conforme HP
-- Highlight muda conforme HP
-- Tracer muda conforme HP
--
-- VIDA:
-- 100% = VERDE
-- 50%  = AMARELO
-- 0%   = VERMELHO
--
-- FARM:
-- WATER -> 100% -> HOME
-- GRASS -> caça várias -> 100% -> HOME
--============================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local LP = Players.LocalPlayer
local PlayerGui = LP:WaitForChild("PlayerGui")

--============================================================
-- CONFIG
--============================================================

local FLY_SPEED = 55
local UNDERGROUND_Y = 10

local FULL_VALUE = 99.5

--============================================================
-- WATER
-- NÃO ALTERADO
--============================================================

local WATER_SCAN_DOWN = 100
local WATER_SCAN_STEP = 1
local WATER_FINE_SPEED = 6

--============================================================
-- GRASS
--============================================================

local SEARCH_RADIUS = 1200
local SEARCH_STEP = 15
local ANGLE_STEP = 15
local SCAN_HEIGHT = 120

local GRASS_WAIT_EAT = 5
local GRASS_STOP_TIMEOUT = 2
local GRASS_IGNORE_DISTANCE = 12
local GRASS_MAX_ATTEMPTS = 50

--============================================================
-- ESP
--============================================================

local ESP_DISTANCE = 500

local ESPEnabled = false
local ShowTracer = false
local ShowHighlight = false

local carcassESPEnabled = false
local CARCASS_ESP_DISTANCE = 500
local carcassESPObjects = {}

local killAuraEnabled, lastAttack = false, 0
local enableUnderground, disableUnderground

local espObjects = {}

--============================================================
-- FARM
--============================================================

local running = false

local holdPosition = false
local holdCF = nil

local homeCF = nil

local actionToken = 0

local estado = "PRONTO"
local canStartText = "nil"

--============================================================
-- CHARACTER
--============================================================

local function getChar()

	return LP.Character
		or LP.CharacterAdded:Wait()

end

local function getRoot()

	return getChar():WaitForChild(
		"HumanoidRootPart"
	)

end

--============================================================
-- UTILS
--============================================================

local Utils = require(
	ReplicatedStorage
		:WaitForChild("AnimalGameFrameworkShared")
		:WaitForChild("Utils")
)

--============================================================
-- CAN START
--============================================================

local function canStart()

	local ok, result = pcall(function()

		return Utils.CanEatDrink.CanStart(
			getChar()
		)

	end)

	if not ok then

		canStartText = "ERRO"

		return nil

	end

	canStartText = tostring(result)

	return result

end

--============================================================
-- CHANGE STATE
--============================================================

local function changeState(state)

	local char = getChar()

	local event =
		char:FindFirstChild(
			"ChangeStateBindableEvent"
		)

	if not event then

		estado = "SEM ChangeState"

		return false

	end

	event:Fire(state)

	return true

end

--============================================================
-- NOVO PAINEL SAVANA HUB - PC + MOBILE
--============================================================
local UIS = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

for _,name in ipairs({"SAVANA_MINI_MENU","SAVANA_MINI_MENU_V2","SAVANA_HUB_FINAL","SavanaSpeedTest"}) do
    local old=PlayerGui:FindFirstChild(name) or game:GetService("CoreGui"):FindFirstChild(name)
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
local tabInfo={{"Visual","VISUAIS"},{"Combat","COMBATE"},{"Move","JOGADOR"},{"Farm","AUTO FARM"}}
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
    local names={Visual="Visuais",Combat="Combate",Move="Jogador",Farm="Auto Farm"}
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
local function slider(parent,title,minv,maxv,initial,callback)
    local f=card(parent,title,nil,78); local val=initial or minv
    local txt=Instance.new("TextLabel",f); txt.AnchorPoint=Vector2.new(1,0); txt.Position=UDim2.new(1,-15,0,10); txt.Size=UDim2.fromOffset(70,20); txt.BackgroundTransparency=1; txt.Text=tostring(val); txt.TextColor3=Color3.fromRGB(211,201,255); txt.TextXAlignment=Enum.TextXAlignment.Right; txt.Font=Enum.Font.GothamBold; txt.TextSize=12
    local bar=Instance.new("Frame",f); bar.Position=UDim2.new(0,14,0,50); bar.Size=UDim2.new(1,-28,0,7); bar.BackgroundColor3=Color3.fromRGB(55,52,65); bar.BorderSizePixel=0; Instance.new("UICorner",bar).CornerRadius=UDim.new(1,0)
    local fill=Instance.new("Frame",bar); fill.BackgroundColor3=ACCENT; fill.BorderSizePixel=0; Instance.new("UICorner",fill).CornerRadius=UDim.new(1,0)
    local knob=Instance.new("Frame",bar); knob.AnchorPoint=Vector2.new(.5,.5); knob.Size=UDim2.fromOffset(16,16); knob.BackgroundColor3=Color3.new(1,1,1); knob.BorderSizePixel=0; Instance.new("UICorner",knob).CornerRadius=UDim.new(1,0)
    local dragging=false
    local function setFromPercent(p) p=math.clamp(p,0,1); val=math.floor(minv+(maxv-minv)*p+.5); fill.Size=UDim2.fromScale(p,1); knob.Position=UDim2.fromScale(p,.5); txt.Text=tostring(val); if callback then callback(val) end end
    local function setX(x) if bar.AbsoluteSize.X>0 then setFromPercent((x-bar.AbsolutePosition.X)/bar.AbsoluteSize.X) end end
    bar.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging=true;setX(i.Position.X) end end)
    knob.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging=true end end)
    UIS.InputChanged:Connect(function(i) if dragging and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then setX(i.Position.X) end end)
    UIS.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging=false end end)
    task.defer(function() setFromPercent((val-minv)/(maxv-minv)) end)
    return f,function() return val end
end
local function toggleSlider(parent,title,desc,initial,minv,maxv,sliderInitial,toggleCallback,sliderCallback)
    local f=card(parent,title,desc,112)
    local state=initial or false

    local b=Instance.new("TextButton",f)
    b.AnchorPoint=Vector2.new(1,0)
    b.Position=UDim2.new(1,-15,0,13)
    b.Size=UDim2.fromOffset(48,25)
    b.BackgroundColor3=state and ACCENT or Color3.fromRGB(55,52,65)
    b.Text=""; b.BorderSizePixel=0
    Instance.new("UICorner",b).CornerRadius=UDim.new(1,0)

    local dot=Instance.new("Frame",b)
    dot.AnchorPoint=Vector2.new(.5,.5)
    dot.Position=state and UDim2.fromScale(.74,.5) or UDim2.fromScale(.26,.5)
    dot.Size=UDim2.fromOffset(19,19)
    dot.BackgroundColor3=Color3.new(1,1,1); dot.BorderSizePixel=0
    Instance.new("UICorner",dot).CornerRadius=UDim.new(1,0)

    local function setToggle(v)
        state=v
        b.BackgroundColor3=v and ACCENT or Color3.fromRGB(55,52,65)
        dot.Position=v and UDim2.fromScale(.74,.5) or UDim2.fromScale(.26,.5)
        if toggleCallback then toggleCallback(v) end
    end
    b.MouseButton1Click:Connect(function() setToggle(not state) end)

    local val=sliderInitial or minv
    local label=Instance.new("TextLabel",f)
    label.Position=UDim2.new(0,14,0,67); label.Size=UDim2.new(.6,0,0,18)
    label.BackgroundTransparency=1; label.Text="Alcance"; label.TextColor3=MUTED
    label.TextXAlignment=Enum.TextXAlignment.Left; label.Font=Enum.Font.Gotham; label.TextSize=10

    local txt=Instance.new("TextLabel",f)
    txt.AnchorPoint=Vector2.new(1,0); txt.Position=UDim2.new(1,-15,0,67); txt.Size=UDim2.fromOffset(60,18)
    txt.BackgroundTransparency=1; txt.Text=tostring(val); txt.TextColor3=Color3.fromRGB(211,201,255)
    txt.TextXAlignment=Enum.TextXAlignment.Right; txt.Font=Enum.Font.GothamBold; txt.TextSize=11

    local bar=Instance.new("Frame",f)
    bar.Position=UDim2.new(0,14,0,94); bar.Size=UDim2.new(1,-28,0,6)
    bar.BackgroundColor3=Color3.fromRGB(55,52,65); bar.BorderSizePixel=0
    Instance.new("UICorner",bar).CornerRadius=UDim.new(1,0)

    local fill=Instance.new("Frame",bar); fill.BackgroundColor3=ACCENT; fill.BorderSizePixel=0
    Instance.new("UICorner",fill).CornerRadius=UDim.new(1,0)
    local knob=Instance.new("Frame",bar); knob.AnchorPoint=Vector2.new(.5,.5); knob.Size=UDim2.fromOffset(15,15)
    knob.BackgroundColor3=Color3.new(1,1,1); knob.BorderSizePixel=0
    Instance.new("UICorner",knob).CornerRadius=UDim.new(1,0)

    local dragging=false
    local function setPercent(p)
        p=math.clamp(p,0,1)
        val=math.floor(minv+(maxv-minv)*p+.5)
        fill.Size=UDim2.fromScale(p,1); knob.Position=UDim2.fromScale(p,.5); txt.Text=tostring(val)
        if sliderCallback then sliderCallback(val) end
    end
    local function setX(x)
        if bar.AbsoluteSize.X>0 then setPercent((x-bar.AbsolutePosition.X)/bar.AbsoluteSize.X) end
    end
    bar.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging=true;setX(i.Position.X) end
    end)
    knob.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging=true end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then setX(i.Position.X) end
    end)
    UIS.InputEnded:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging=false end
    end)
    task.defer(function() setPercent((val-minv)/(maxv-minv)) end)
    return f,setToggle,function() return state end
end

local function action(parent,text,callback)
    local b=Instance.new("TextButton",parent); b.Size=UDim2.new(1,-8,0,52); b.BackgroundColor3=CARD; b.BorderSizePixel=0; b.Text=text; b.TextColor3=Color3.new(1,1,1); b.Font=Enum.Font.GothamSemibold; b.TextSize=13; Instance.new("UICorner",b).CornerRadius=UDim.new(0,10); local s=Instance.new("UIStroke",b);s.Color=Color3.fromRGB(55,49,72);s.Transparency=.55; b.MouseButton1Click:Connect(callback); return b
end

local hitboxEnabled=false; local hitboxRange=50
local autoGrabEnabled=false; local autoGrabRange=50
local autoDesgrabEnabled=false
local speedValue=0
local infiniteStats=false
local sempreDiaEnabled=false

-- SATOSHI FLY - velocidade estável 16
local flyEnabled=false
local flyConnection=nil
local flyAttachment=nil
local flyVelocity=nil

local function stopFly()
    flyEnabled=false
    if flyConnection then flyConnection:Disconnect(); flyConnection=nil end
    if flyVelocity then flyVelocity:Destroy(); flyVelocity=nil end
    if flyAttachment then flyAttachment:Destroy(); flyAttachment=nil end
    local char=LP.Character
    if char then
        local hum=char:FindFirstChildOfClass("Humanoid")
        local root=char:FindFirstChild("HumanoidRootPart")
        if hum then hum.AutoRotate=true end
        if root then
            root.AssemblyLinearVelocity=Vector3.zero
            root.AssemblyAngularVelocity=Vector3.zero
        end
    end
end

local function startFly()
    if flyEnabled then return end
    local char=LP.Character
    if not char then return end
    local hum=char:FindFirstChildOfClass("Humanoid")
    local root=char:FindFirstChild("HumanoidRootPart")
    if not hum or not root then return end

    flyEnabled=true
    hum.AutoRotate=false

    flyAttachment=Instance.new("Attachment")
    flyAttachment.Name="SatoshiFlyAttachment"
    flyAttachment.Parent=root

    flyVelocity=Instance.new("LinearVelocity")
    flyVelocity.Name="SatoshiFlyVelocity"
    flyVelocity.Attachment0=flyAttachment
    flyVelocity.RelativeTo=Enum.ActuatorRelativeTo.World
    flyVelocity.VelocityConstraintMode=Enum.VelocityConstraintMode.Vector
    flyVelocity.MaxForce=math.huge
    flyVelocity.VectorVelocity=Vector3.zero
    flyVelocity.Parent=root

    flyConnection=RunService.RenderStepped:Connect(function()
        if not flyEnabled or not root.Parent then stopFly(); return end
        local camera=Workspace.CurrentCamera
        if not camera then return end
        local move=hum.MoveDirection
        if move.Magnitude < 0.05 then
            flyVelocity.VectorVelocity=Vector3.zero
            root.AssemblyAngularVelocity=Vector3.zero
            return
        end
        local look=camera.CFrame.LookVector
        local right=camera.CFrame.RightVector
        local flatLook=Vector3.new(look.X,0,look.Z)
        if flatLook.Magnitude>0.001 then flatLook=flatLook.Unit else flatLook=Vector3.new(0,0,-1) end
        local flatRight=Vector3.new(right.X,0,right.Z)
        if flatRight.Magnitude>0.001 then flatRight=flatRight.Unit else flatRight=Vector3.new(1,0,0) end
        local forwardAmount=move:Dot(flatLook)
        local rightAmount=move:Dot(flatRight)
        local direction=(look*forwardAmount)+(right*rightAmount)
        if direction.Magnitude>1 then direction=direction.Unit end
        flyVelocity.VectorVelocity=direction*16
        root.AssemblyAngularVelocity=Vector3.zero
    end)
end

local _,setESP=toggleSlider(pages.Visual,"ESP Players","Nome, animal, vida e distância.",false,0,1500,500,function(v) ESPEnabled=v end,function(v) ESP_DISTANCE=v end)
local _,setCarcassESP=toggleSlider(pages.Visual,"Carcaças Mortas","Destaca carcaças e mostra a distância.",false,0,1000,500,function(v) carcassESPEnabled=v end,function(v) CARCASS_ESP_DISTANCE=v end)
local _,setTracer=toggle(pages.Visual,"Linha Rastreadora","Linha até os jogadores visíveis.",false,function(v) ShowTracer=v end)
local _,setHighlight=toggle(pages.Visual,"Contorno","Destaca o personagem conforme a vida.",false,function(v) ShowHighlight=v end)
local _,setSempreDia=toggle(pages.Visual,"Sempre Dia","Trava o relógio visual em 12:00.",false,function(v) sempreDiaEnabled=v end)

local killAuraButton=Instance.new("TextButton") -- compatibilidade com a lógica existente

-- Kill Aura e Hitbox nunca ficam ativos juntos.
-- Se o Hitbox estava ligado antes da Aura, ele volta quando a Aura for desligada.
local setHitbox
local hitboxWasEnabledBeforeAura=false

local _,setKill=toggle(pages.Combat,"Aura de Ataque","Ataca automaticamente alvos em até 50 studs.",false,function(v)
    killAuraEnabled=v
    lastAttack=0

    if v then
        hitboxWasEnabledBeforeAura=hitboxEnabled
        if hitboxEnabled and setHitbox then
            setHitbox(false)
        end
    else
        if hitboxWasEnabledBeforeAura and setHitbox then
            setHitbox(true)
        end
        hitboxWasEnabledBeforeAura=false
    end
end)

local _
_,setHitbox=toggleSlider(pages.Combat,"Hitbox","Amplia o alcance do ataque manual.",false,0,60,50,function(v) hitboxEnabled=v end,function(v) hitboxRange=v end)
local _,setGrab=toggleSlider(pages.Combat,"Agarrar Automático","Tenta agarrar o alvo válido mais próximo.",false,0,50,50,function(v) autoGrabEnabled=v end,function(v) autoGrabRange=v end)
local _,setDesgrab=toggle(pages.Combat,"Desagarrar Automático","Executa automaticamente o minigame para se soltar.",false,function(v) autoDesgrabEnabled=v end)

slider(pages.Move,"Velocidade",0,100,0,function(v) speedValue=v end)
local _,setInf=toggle(pages.Move,"Stamina + Oxigênio Infinitos","Mantém stamina e oxigênio em 100.",false,function(v) infiniteStats=v end)
local _,setFly=toggle(pages.Move,"Fly","Voa seguindo a câmera e o analógico/WASD. Velocidade: 16.",false,function(v)
    if v then startFly() else stopFly() end
end)
local undergroundButton=Instance.new("TextButton") -- compatibilidade
local _,setUnder=toggle(pages.Move,"Subsolo","Ativa o modo invisível/subsolo do script-base.",false,function(v) if v then enableUnderground() else disableUnderground() end end)

-- AUTO FARM unificado: fome <= 65% / água <= 70%
local autoFarmEnabled = false
local autoFarmBusy = false -- trava: nunca deixa água e comida iniciarem juntas
local _,setAutoFarm=toggle(
    pages.Farm,
    "Auto Farm",
    "Água em 70%: bebe até 100%. Fome em 65%: come até 100%.",
    false,
    function(v)
        autoFarmEnabled = v
        if not v and running then
            -- O gerenciador para de iniciar novas rotinas. A rotina atual é
            -- cancelada pelas mesmas variáveis usadas pelo farm original.
            actionToken += 1
            running = false
            holdPosition = false
            holdCF = nil
            pcall(function() changeState("ExitEating") end)
            pcall(function() changeState("ExitDrinking") end)
            estado = "AUTO FARM OFF"
        elseif v then
            estado = "AUTO FARM ON"
        end
    end
)
local beberAguaManual=false
local _,setBeberAgua=toggle(
    pages.Farm,
    "Beber Água",
    "Liga para procurar água e beber. Desligue a qualquer momento para cancelar e voltar.",
    false,
    function(v)
        beberAguaManual=v

        if v then
            if running then
                estado="AGUARDE A TAREFA ATUAL"
                beberAguaManual=false
                task.defer(function() setBeberAgua(false) end)
                return
            end

            estado="BEBER ÁGUA MANUAL"
            waterTest()

            -- Quando terminar normalmente, desliga o botão sozinho.
            task.spawn(function()
                while gui.Parent and beberAguaManual and running do
                    task.wait(0.15)
                end
                if gui.Parent and beberAguaManual and not running then
                    beberAguaManual=false
                    setBeberAgua(false)
                end
            end)
        else
            -- Se foi desligado durante a bebida, cancela a rotina atual.
            if running then
                actionToken += 1
                running=false
                holdPosition=false
                holdCF=nil

                pcall(function() changeState("ExitDrinking") end)

                -- Volta imediatamente ao ponto salvo pela rotina de água.
                local root=getRoot()
                if homeCF then
                    root.CFrame=homeCF
                    root.AssemblyLinearVelocity=Vector3.zero
                    root.AssemblyAngularVelocity=Vector3.zero
                    estado="BEBER ÁGUA CANCELADO"
                else
                    estado="CANCELADO"
                end
            end
        end
    end
)

local status=Instance.new("TextLabel",pages.Farm); status.Size=UDim2.new(1,-8,0,38); status.BackgroundTransparency=1; status.Text="AUTO FARM OFF"; status.TextColor3=MUTED; status.Font=Enum.Font.GothamMedium; status.TextSize=11

-- aliases antigos sem interface; mantêm compatibilidade com o restante do arquivo
local waterButton=Instance.new("TextButton")
local grassButton=Instance.new("TextButton")
local homeButton=Instance.new("TextButton")
local stopButton=Instance.new("TextButton")

-- aliases esperados pelo código antigo
local espButton=Instance.new("TextButton"); local tracerButton=Instance.new("TextButton"); local highlightButton=Instance.new("TextButton")
-- os botões antigos ficam sem pai; conexões antigas não aparecem na interface

local profile=Instance.new("TextLabel",sidebar); profile.AnchorPoint=Vector2.new(0,1); profile.Position=UDim2.fromScale(.08,.965); profile.Size=UDim2.fromScale(.84,.09); profile.BackgroundTransparency=1; profile.Text=LP.DisplayName.."\n@"..LP.Name; profile.TextColor3=Color3.fromRGB(225,223,235); profile.TextXAlignment=Enum.TextXAlignment.Left; profile.TextYAlignment=Enum.TextYAlignment.Center; profile.Font=Enum.Font.GothamMedium; profile.TextSize=10

local bubble=Instance.new("TextButton",gui); bubble.AnchorPoint=Vector2.new(.5,.5); bubble.Position=UDim2.fromScale(.075,.55); bubble.Size=UDim2.fromOffset(52,52); bubble.BackgroundColor3=Color3.fromRGB(25,22,35); bubble.Text="🦁"; bubble.TextScaled=true; bubble.Visible=false; bubble.Active=true; bubble.BorderSizePixel=0; Instance.new("UICorner",bubble).CornerRadius=UDim.new(1,0); local bst=Instance.new("UIStroke",bubble);bst.Color=ACCENT
local menuOpen=true
local function setMenu(v) menuOpen=v; frame.Visible=v; bubble.Visible=not v end
close.MouseButton1Click:Connect(function() setMenu(false) end)
UIS.InputBegan:Connect(function(input,gp) if not gp and input.KeyCode==Enum.KeyCode.RightShift then setMenu(not menuOpen) end end)
local function makeDraggable(handle,target,onTap)
 local dragging,moved=false,false; local start,pos,current
 handle.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging=true;moved=false;start=i.Position;pos=target.Position end end)
 handle.InputChanged:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch then current=i end end)
 UIS.InputChanged:Connect(function(i) if dragging and i==current and Workspace.CurrentCamera then local d=i.Position-start;if d.Magnitude>6 then moved=true end;local vp=Workspace.CurrentCamera.ViewportSize;target.Position=UDim2.fromScale(pos.X.Scale+d.X/vp.X,pos.Y.Scale+d.Y/vp.Y) end end)
 UIS.InputEnded:Connect(function(i) if dragging and (i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch) then dragging=false;if onTap and not moved then onTap() end end end)
end
makeDraggable(header,frame); makeDraggable(bubble,bubble,function() setMenu(true) end); openPage("Visual")

--============================================================
-- COR DA VIDA
--
-- 100% = VERDE
-- 50% = AMARELO
-- 0% = VERMELHO
--============================================================

local function getHealthColor(hum)

	if not hum then

		return Color3.new(
			1,
			1,
			1
		)

	end

	if hum.MaxHealth <= 0 then

		return Color3.new(
			1,
			1,
			1
		)

	end

	local percent =
		math.clamp(
			hum.Health
			/
			hum.MaxHealth,
			0,
			1
		)

	return Color3.new(
		1 - percent,
		percent,
		0
	)

end

--============================================================
-- REMOVER ESP
--============================================================

local function removeESP(player)

	local data =
		espObjects[player]

	if not data then
		return
	end

	for _, obj in pairs(data) do

		pcall(function()

			if typeof(obj) ==
				"Instance"
			then

				obj:Destroy()

			end

		end)

	end

	espObjects[player] =
		nil

end

--============================================================
-- CRIAR ESP
--============================================================

local function createESP(player)

	if player == LP then
		return
	end

	removeESP(player)

	local char =
		player.Character

	if not char then
		return
	end

	local root =
		char:FindFirstChild(
			"HumanoidRootPart"
		)

	if not root then
		return
	end

	--========================================================
	-- BILLBOARD
	--========================================================

	local billboard =
		Instance.new(
			"BillboardGui"
		)

	billboard.Name =
		"SAVANA_ESP"

	billboard.Adornee =
		root

	billboard.Size =
		UDim2.fromOffset(
			300,
			35
		)

	billboard.StudsOffset =
		Vector3.new(
			0,
			4,
			0
		)

	billboard.AlwaysOnTop =
		true

	billboard.Parent =
		gui

	--========================================================
	-- TEXTO
	--========================================================

	local label =
		Instance.new(
			"TextLabel"
		)

	label.Size =
		UDim2.fromScale(
			1,
			1
		)

	label.BackgroundTransparency =
		1

	label.TextColor3 =
		Color3.new(
			0,
			1,
			0
		)

	label.TextStrokeTransparency =
		0.35

	label.TextStrokeColor3 =
		Color3.new(
			0,
			0,
			0
		)

	label.TextSize =
		11

	label.Font =
		Enum.Font.GothamBold

	label.Parent =
		billboard

	--========================================================
	-- HIGHLIGHT
	--========================================================

	local highlight =
		Instance.new(
			"Highlight"
		)

	highlight.Name =
		"SAVANA_HIGHLIGHT"

	highlight.Adornee =
		char

	highlight.FillColor =
		Color3.new(
			0,
			1,
			0
		)

	highlight.OutlineColor =
		Color3.new(
			0,
			1,
			0
		)

	highlight.FillTransparency =
		0.82

	highlight.OutlineTransparency =
		0

	highlight.DepthMode =
		Enum.HighlightDepthMode.AlwaysOnTop

	highlight.Enabled =
		ShowHighlight

	highlight.Parent =
		gui

	--========================================================
	-- TRACER
	--========================================================

	local originPart =
		Instance.new(
			"Part"
		)

	originPart.Name =
		"ESP_TRACER_ORIGIN"

	originPart.Size =
		Vector3.new(
			0.05,
			0.05,
			0.05
		)

	originPart.Transparency =
		1

	originPart.Anchored =
		true

	originPart.CanCollide =
		false

	originPart.CanTouch =
		false

	originPart.CanQuery =
		false

	originPart.Parent =
		Workspace

	--========================================================

	local originAttachment =
		Instance.new(
			"Attachment"
		)

	originAttachment.Parent =
		originPart

	--========================================================

	local targetAttachment =
		Instance.new(
			"Attachment"
		)

	targetAttachment.Name =
		"SAVANA_TRACER_TARGET"

	targetAttachment.Parent =
		root

	--========================================================

	local beam =
		Instance.new(
			"Beam"
		)

	beam.Attachment0 =
		originAttachment

	beam.Attachment1 =
		targetAttachment

	beam.FaceCamera =
		true

	beam.Width0 =
		0.025

	beam.Width1 =
		0.025

	-- inicialmente verde
	beam.Color =
		ColorSequence.new(
			Color3.new(
				0,
				1,
				0
			)
		)

	beam.Transparency =
		NumberSequence.new(
			0
		)

	beam.Enabled =
		ShowTracer

	beam.Parent =
		originPart

	--========================================================
	-- SALVA
	--========================================================

	espObjects[player] = {

		Billboard =
			billboard,

		Label =
			label,

		Highlight =
			highlight,

		OriginPart =
			originPart,

		TargetAttachment =
			targetAttachment,

		Beam =
			beam

	}

end

--============================================================
-- ESP CARCAÇAS MORTAS
--============================================================
local carcassesFolderConnection
local carcassesRemovedConnection

local function removeCarcassESP(carcass)
    local data=carcassESPObjects[carcass]
    if not data then return end
    if data.Billboard then data.Billboard:Destroy() end
    if data.Highlight then data.Highlight:Destroy() end
    carcassESPObjects[carcass]=nil
end

local function createCarcassESP(carcass)
    if carcassESPObjects[carcass] or not carcass or not carcass:IsA("Model") then return end

    local root=carcass:FindFirstChild("HumanoidRootPart") or carcass.PrimaryPart
    if not root then
        root=carcass:WaitForChild("HumanoidRootPart",4)
    end
    if not root then return end

    local highlight=Instance.new("Highlight")
    highlight.Name="SATOSHI_CARCASS_HIGHLIGHT"
    highlight.Adornee=carcass
    highlight.DepthMode=Enum.HighlightDepthMode.AlwaysOnTop
    highlight.FillTransparency=.75
    highlight.OutlineTransparency=0
    highlight.Enabled=false
    highlight.Parent=gui

    local billboard=Instance.new("BillboardGui")
    billboard.Name="SATOSHI_CARCASS_INFO"
    billboard.Adornee=root
    billboard.Size=UDim2.fromOffset(180,30)
    billboard.StudsOffset=Vector3.new(0,3,0)
    billboard.AlwaysOnTop=true
    billboard.Enabled=false
    billboard.Parent=gui

    local label=Instance.new("TextLabel")
    label.Size=UDim2.fromScale(1,1)
    label.BackgroundTransparency=1
    label.Text="☠ CARCAÇA"
    label.TextColor3=Color3.new(1,1,1)
    label.TextStrokeTransparency=.25
    label.Font=Enum.Font.GothamBold
    label.TextSize=12
    label.Parent=billboard

    carcassESPObjects[carcass]={
        Root=root,
        Billboard=billboard,
        Label=label,
        Highlight=highlight
    }
end

local function connectCarcassesFolder(folder)
    if carcassesFolderConnection then carcassesFolderConnection:Disconnect() end
    if carcassesRemovedConnection then carcassesRemovedConnection:Disconnect() end

    for _,carcass in ipairs(folder:GetChildren()) do
        task.spawn(createCarcassESP,carcass)
    end

    carcassesFolderConnection=folder.ChildAdded:Connect(function(carcass)
        task.wait(.1)
        createCarcassESP(carcass)
    end)

    carcassesRemovedConnection=folder.ChildRemoved:Connect(removeCarcassESP)
end

local currentCarcassesFolder=Workspace:FindFirstChild("CarcassesStorageModel")
if currentCarcassesFolder then
    connectCarcassesFolder(currentCarcassesFolder)
end

Workspace.ChildAdded:Connect(function(child)
    if child:IsA("Model") and child.Name=="CarcassesStorageModel" then
        connectCarcassesFolder(child)
    end
end)

RunService.RenderStepped:Connect(function()
    local char=LP.Character
    local myRoot=char and char:FindFirstChild("HumanoidRootPart")
    if not myRoot then return end

    for carcass,data in pairs(carcassESPObjects) do
        if not carcass.Parent or not data.Root or not data.Root.Parent then
            removeCarcassESP(carcass)
        else
            local distance=(data.Root.Position-myRoot.Position).Magnitude
            local visible=carcassESPEnabled and CARCASS_ESP_DISTANCE>0 and distance<=CARCASS_ESP_DISTANCE

            data.Billboard.Enabled=visible
            data.Highlight.Enabled=visible

            if visible then
                data.Label.Text="☠ CARCAÇA | "..math.floor(distance).."m"
            end
        end
    end
end)

--============================================================
-- ESP LOOP - AUTO REPARO
--============================================================
local function espNeedsRepair(data,char,root)
 if not data then return true end
 if not data.Billboard or not data.Billboard.Parent or data.Billboard.Adornee~=root then return true end
 if not data.Label or not data.Label.Parent then return true end
 if not data.Highlight or not data.Highlight.Parent or data.Highlight.Adornee~=char then return true end
 if not data.OriginPart or not data.OriginPart.Parent then return true end
 if not data.TargetAttachment or not data.TargetAttachment.Parent or data.TargetAttachment.Parent~=root then return true end
 if not data.Beam or not data.Beam.Parent or not data.Beam.Attachment0 or data.Beam.Attachment1~=data.TargetAttachment then return true end
 return false
end

RunService.RenderStepped:Connect(function()
 local camera=Workspace.CurrentCamera
 local myChar=LP.Character
 local myRoot=myChar and myChar:FindFirstChild("HumanoidRootPart")
 if not myRoot then return end
 for _,player in ipairs(Players:GetPlayers()) do
  if player~=LP then
   local char=player.Character
   local root=char and char:FindFirstChild("HumanoidRootPart")
   if char and root then
    local data=espObjects[player]
    if espNeedsRepair(data,char,root) then
     createESP(player)
     data=espObjects[player]
    end
    if data then
     local distance=(root.Position-myRoot.Position).Magnitude
     local visible=ESPEnabled and ESP_DISTANCE>0 and distance<=ESP_DISTANCE
     data.Billboard.Enabled=visible
     data.Highlight.Enabled=visible and ShowHighlight
     data.Beam.Enabled=visible and ShowTracer
     local animal=char:GetAttribute("AnimalName") or char:GetAttribute("AnimalClass") or "?"
     local hum=char:FindFirstChildOfClass("Humanoid")
     local hp,maxHp=0,0
     if hum then hp=math.floor(hum.Health);maxHp=math.floor(hum.MaxHealth) end
     data.Label.Text=player.DisplayName.." | "..tostring(animal).." | ♥ "..tostring(hp).." / "..tostring(maxHp).." | "..math.floor(distance).."m"
     local healthColor=getHealthColor(hum)
     data.Label.TextColor3=healthColor
     data.Beam.Color=ColorSequence.new(healthColor)
     data.Highlight.FillColor=healthColor
     data.Highlight.OutlineColor=healthColor
     if data.OriginPart and data.OriginPart.Parent and camera then
      data.OriginPart.CFrame=camera.CFrame*CFrame.new(0,-2.5,-1)
     end
    end
   elseif espObjects[player] then
    removeESP(player)
   end
  end
 end
end)

--============================================================
-- PLAYERS
--============================================================

Players.PlayerAdded:
Connect(function(player)

	player.CharacterAdded:
	Connect(function()

		task.wait(1)

		createESP(player)

	end)

end)

Players.PlayerRemoving:
Connect(function(player)

	removeESP(player)

end)

for _, player in ipairs(
	Players:GetPlayers()
) do

	if player ~= LP then

		if player.Character then

			createESP(player)

		end

		player.CharacterAdded:
		Connect(function()

			task.wait(1)

			createESP(player)

		end)

	end

end

--============================================================
-- HOLD POSITION
--============================================================

RunService.Heartbeat:
Connect(function()

	if not holdPosition then
		return
	end

	if not holdCF then
		return
	end

	local char =
		LP.Character

	if not char then
		return
	end

	local root =
		char:FindFirstChild(
			"HumanoidRootPart"
		)

	if not root then
		return
	end

	root.AssemblyLinearVelocity =
		Vector3.zero

	root.AssemblyAngularVelocity =
		Vector3.zero

	root.CFrame =
		holdCF

end)

--============================================================
-- FLY
--============================================================

local function flyTo(
	target,
	speed
)

	speed =
		speed or FLY_SPEED

	while running do

		local root =
			getRoot()

		local atual =
			root.Position

		local delta =
			target - atual

		local distance =
			delta.Magnitude

		if distance <= 0.25 then

			local rotation =
				root.CFrame
				-
				root.CFrame.Position

			root.CFrame =
				CFrame.new(
					target
				)
				*
				rotation

			root.AssemblyLinearVelocity =
				Vector3.zero

			root.AssemblyAngularVelocity =
				Vector3.zero

			return true

		end

		local dt =
			RunService.Heartbeat:
			Wait()

		local step =
			math.min(
				speed * dt,
				distance
			)

		local newPos =
			atual
			+
			delta.Unit
			*
			step

		local rotation =
			root.CFrame
			-
			root.CFrame.Position

		root.CFrame =
			CFrame.new(
				newPos
			)
			*
			rotation

		root.AssemblyLinearVelocity =
			Vector3.zero

		root.AssemblyAngularVelocity =
			Vector3.zero

	end

	return false

end

--============================================================
-- DESCER
--============================================================

local function descerParaSubsolo()

	local root =
		getRoot()

	estado =
		"DESCENDO ↓"

	return flyTo(

		Vector3.new(

			root.Position.X,

			UNDERGROUND_Y,

			root.Position.Z

		),

		FLY_SPEED

	)

end

--============================================================
-- VOLTAR HOME
--============================================================

local function voltarAutomatico()

	holdPosition =
		false

	holdCF =
		nil

	if not homeCF then

		running =
			false

		estado =
			"SEM HOME"

		return

	end

	running =
		true

	estado =
		"VOLTANDO HOME"

	local ok =
		flyTo(
			homeCF.Position,
			FLY_SPEED
		)

	if ok then

		local root =
			getRoot()

		root.CFrame =
			homeCF

		root.AssemblyLinearVelocity =
			Vector3.zero

		root.AssemblyAngularVelocity =
			Vector3.zero

	end

	running =
		false

	estado =
		"PRONTO"

	canStartText =
		"nil"

end

--============================================================
-- WATER
-- NÃO MEXER
--============================================================

local function procurarDrinkVertical()

	local root =
		getRoot()

	local fixedX =
		root.Position.X

	local fixedZ =
		root.Position.Z

	local startY =
		root.Position.Y

	estado =
		"AJUSTANDO WATER"

	if canStart() ==
		"Drink"
	then

		holdCF =
			getRoot().CFrame

		return true

	end

	for amount =
		0,
		WATER_SCAN_DOWN,
		WATER_SCAN_STEP
	do

		if not running then
			return false
		end

		local targetY =
			startY
			-
			amount

		estado =
			"WATER Y "
			..
			string.format(
				"%.1f",
				targetY
			)

		local target =
			Vector3.new(

				fixedX,

				targetY,

				fixedZ

			)

		if not flyTo(
			target,
			WATER_FINE_SPEED
		) then

			return false

		end

		local rootNow =
			getRoot()

		rootNow.AssemblyLinearVelocity =
			Vector3.zero

		rootNow.AssemblyAngularVelocity =
			Vector3.zero

		task.wait(0.08)

		if canStart() ==
			"Drink"
		then

			holdCF =
				rootNow.CFrame

			return true

		end

	end

	return false

end

--============================================================
-- WATER FARM
--============================================================

local function waterTest()
    if running then
        estado = "AGUARDE A TAREFA ATUAL"
        return
    end

    actionToken += 1
    local token = actionToken
    running = true
    holdPosition = false
    holdCF = nil

    local root = getRoot()
    local originalCF = root.CFrame

    -- O HOME é exatamente o ponto onde começou esta tarefa.
    homeCF = originalCF
    estado = "PROCURANDO ÁGUA"

    task.spawn(function()
        local foundCF = nil
        local rotation = originalCF - originalCF.Position
        local x, z = originalCF.Position.X, originalCF.Position.Z
        local startY = originalCF.Position.Y

        -- Desce 1 stud por vez e testa a camada em cada posição.
        for offset = 1, WATER_SCAN_DOWN do
            if not running or actionToken ~= token then
                return
            end

            root = getRoot()
            local y = startY - offset
            root.CFrame = CFrame.new(x, y, z) * rotation
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero

            RunService.Heartbeat:Wait()

            if canStart() == "Drink" then
                foundCF = root.CFrame
                break
            end
        end

        -- Nunca deixa preso embaixo do mapa.
        if not foundCF then
            estado = "ÁGUA NÃO ENCONTRADA"
            root = getRoot()
            root.CFrame = originalCF
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            running = false
            return
        end

        -- Segura exatamente na camada reconhecida como Drink.
        root = getRoot()
        root.CFrame = foundCF
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        holdCF = foundCF
        holdPosition = true
        estado = "ÁGUA ENCONTRADA"

        -- Dá tempo para o cliente estabilizar e confirma novamente.
        local recognized = false
        local recognizeStart = os.clock()
        while running and actionToken == token and os.clock() - recognizeStart < 4 do
            root = getRoot()
            root.CFrame = foundCF
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero

            if canStart() == "Drink" then
                recognized = true
                break
            end
            task.wait(0.10)
        end

        if not recognized then
            estado = "DRINK NÃO RECONHECIDO"
            holdPosition = false
            holdCF = nil
            root = getRoot()
            root.CFrame = originalCF
            running = false
            return
        end

        -- Mantém o atraso que já havia funcionado no script-base.
        estado = "PREPARANDO BEBIDA"
        task.wait(1.5)

        if not running or actionToken ~= token then
            return
        end

        local ok = changeState("Drinking")
        if not ok then
            estado = "FALHA DRINKING"
            holdPosition = false
            holdCF = nil
            root = getRoot()
            root.CFrame = originalCF
            running = false
            return
        end

        estado = "BEBENDO"

        -- Continua na camada até Water chegar a 100%.
        while running and actionToken == token do
            local char = LP.Character
            if not char then
                task.wait(0.10)
                continue
            end

            local water = char:GetAttribute("Water") or 0
            estado = "ÁGUA " .. math.floor(water) .. "%"

            if water >= FULL_VALUE then
                break
            end

            root = getRoot()
            root.CFrame = foundCF
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            task.wait(0.20)
        end

        if actionToken ~= token then
            return
        end

        pcall(function()
            changeState("ExitDrinking")
        end)

        holdPosition = false
        holdCF = nil
        estado = "ÁGUA 100% • VOLTANDO"

        -- Finaliza a tarefa de água somente DEPOIS de voltar.
        root = getRoot()
        root.CFrame = originalCF
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero

        task.wait(0.20)
        running = false
        estado = "ÁGUA FINALIZADA"
    end)
end

--============================================================
-- GRASS RAYCAST
--============================================================

local rayParams =
	RaycastParams.new()

rayParams.FilterType =
	Enum.RaycastFilterType.Exclude

local function updateFilter()

	rayParams.FilterDescendantsInstances = {
		getChar()
	}

end

--============================================================
-- GRASS USADAS
--============================================================

local grassUsadas = {}

local function grassUsada(pos)

	for _, old in ipairs(
		grassUsadas
	) do

		local d =
			Vector3.new(

				pos.X - old.X,

				0,

				pos.Z - old.Z

			).Magnitude

		if d <=
			GRASS_IGNORE_DISTANCE
		then

			return true

		end

	end

	return false

end

--============================================================
-- PROCURA NOVA GRASS
--============================================================

local function procurarGrass()

	local origem =
		getRoot().Position

	updateFilter()

	estado =
		"CAÇANDO GRASS"

	for radius =
		0,
		SEARCH_RADIUS,
		SEARCH_STEP
	do

		if not running then
			return nil
		end

		for angle =
			0,
			345,
			ANGLE_STEP
		do

			local rad =
				math.rad(
					angle
				)

			local x =
				origem.X
				+
				math.cos(
					rad
				)
				*
				radius

			local z =
				origem.Z
				+
				math.sin(
					rad
				)
				*
				radius

			local hit =
				Workspace:Raycast(

					Vector3.new(

						x,

						origem.Y
							+
							SCAN_HEIGHT,

						z

					),

					Vector3.new(

						0,

						-SCAN_HEIGHT
							*
							2,

						0

					),

					rayParams

				)

			if hit
				and
				hit.Material
				==
				Enum.Material.Grass
			then

				local pos =
					hit.Position
					+
					Vector3.new(
						0,
						3,
						0
					)

				if not grassUsada(
					pos
				) then

					return pos

				end

			end

		end

		task.wait()

	end

	return nil

end

--============================================================
-- ESPERA EAT
--============================================================

local function esperarEat()

	local start =
		os.clock()

	estado =
		"ESPERANDO EAT"

	while running
		and
		os.clock()
			-
			start
			<
			GRASS_WAIT_EAT
	do

		local root =
			getRoot()

		root.AssemblyLinearVelocity =
			Vector3.zero

		root.AssemblyAngularVelocity =
			Vector3.zero

		if canStart() ==
			"Eat"
		then

			return true

		end

		task.wait(0.2)

	end

	return false

end

--============================================================
-- COME UMA GRASS
--============================================================

local function comerUmaGrass(
	pos,
	token
)

	estado =
		"INDO GRASS"

	if not flyTo(
		pos,
		FLY_SPEED
	) then

		return false,
			"CANCELADO"

	end

	local root =
		getRoot()

	root.AssemblyLinearVelocity =
		Vector3.zero

	root.AssemblyAngularVelocity =
		Vector3.zero

	--========================================================
	-- ESPERA O JOGO RECONHECER A GRASS
	--========================================================

	task.wait(0.5)

	if not esperarEat() then

		return false,
			"OUTRA"

	end

	--========================================================
	-- SEGURA
	--========================================================

	root =
		getRoot()

	holdCF =
		root.CFrame

	holdPosition =
		true

	task.wait(0.1)

	--========================================================
	-- COME
	--========================================================

	changeState(
		"Eating"
	)

	estado =
		"COMENDO"

	local oldFood =
		getChar():
		GetAttribute(
			"Food"
		) or 0

	local lastIncrease =
		os.clock()

	--========================================================
	-- ESPERA ESSA GRASS ACABAR
	--========================================================

	while gui.Parent
		and
		actionToken ==
		token
	do

		task.wait(0.2)

		local food =
			getChar():
			GetAttribute(
				"Food"
			) or 0

		estado =
			"FOOD "
			..
			math.floor(
				food
			)
			..
			"%"

		--====================================================
		-- 100%
		--====================================================

		if food >=
			FULL_VALUE
		then

			changeState(
				"ExitEating"
			)

			holdPosition =
				false

			holdCF =
				nil

			return true,
				"CHEIO"

		end

		--====================================================
		-- A GRASS AINDA ESTÁ DANDO FOOD
		--====================================================

		if food >
			oldFood + 0.01
		then

			oldFood =
				food

			lastIncrease =
				os.clock()

		end

		--====================================================
		-- PAROU DE DAR FOOD
		--
		-- GRASS FOI COMIDA/SUMIU
		--====================================================

		if os.clock()
			-
			lastIncrease
			>=
			GRASS_STOP_TIMEOUT
		then

			estado =
				"PRÓXIMA GRASS"

			changeState(
				"ExitEating"
			)

			holdPosition =
				false

			holdCF =
				nil

			task.wait(0.15)

			return false,
				"OUTRA"

		end

	end

	holdPosition =
		false

	holdCF =
		nil

	return false,
		"CANCELADO"

end

--============================================================
-- AUTO FARM GRASS
--============================================================

local function grassTest()

	if running then
		return
	end

	actionToken += 1

	local token =
		actionToken

	grassUsadas =
		{}

	holdPosition =
		false

	holdCF =
		nil

	running =
		true

	--========================================================
	-- SALVA POSIÇÃO INICIAL
	--========================================================

	homeCF =
		getRoot().CFrame

	task.spawn(function()

		local food =
			getChar():
			GetAttribute(
				"Food"
			) or 0

		if food >=
			FULL_VALUE
		then

			estado =
				"FOOD 100%"

			running =
				false

			return

		end

		--====================================================
		-- DESCE UMA VEZ
		--====================================================

		if not descerParaSubsolo() then

			running =
				false

			return

		end

		--====================================================
		-- CAÇA GRASS ATÉ 100%
		--====================================================

		for tentativa =
			1,
			GRASS_MAX_ATTEMPTS
		do

			if actionToken ~=
				token
			then

				return

			end

			if not running then
				return
			end

			food =
				getChar():
				GetAttribute(
					"Food"
				) or 0

			--================================================
			-- CHEIO
			--================================================

			if food >=
				FULL_VALUE
			then

				break

			end

			estado =
				"CAÇANDO GRASS "
				..
				tostring(
					tentativa
				)

			--================================================
			-- ACHA OUTRA GRASS
			--================================================

			local grass =
				procurarGrass()

			if not grass then

				estado =
					"SEM GRASS"

				running =
					false

				return

			end

			--================================================
			-- MARCA ESSA REGIÃO
			--================================================

			table.insert(
				grassUsadas,
				grass
			)

			--================================================
			-- VAI COMER
			--================================================

			local cheio,
				motivo =
				comerUmaGrass(
					grass,
					token
				)

			if cheio then

				break

			end

			if motivo ==
				"CANCELADO"
			then

				return

			end

			--================================================
			-- GRASS ACABOU
			-- PROCURA A PRÓXIMA
			--================================================

			estado =
				"CAÇANDO PRÓXIMA"

			task.wait(0.15)

		end

		--====================================================
		-- CONFIRMA FOOD
		--====================================================

		food =
			getChar():
			GetAttribute(
				"Food"
			) or 0

		if food >=
			FULL_VALUE
		then

			estado =
				"FOOD 100%"

			changeState(
				"ExitEating"
			)

			holdPosition =
				false

			holdCF =
				nil

			task.wait(0.2)

			--================================================
			-- VOLTA PARA ONDE COMEÇOU
			--================================================

			voltarAutomatico()

			return

		end

		estado =
			"FIM GRASS"

		running =
			false

	end)

end

--============================================================
-- AUTO FARM ÚNICO / FILA REAL
-- 1) Se água <= 70%, termina ÁGUA até 100% e volta HOME.
-- 2) SOMENTE depois verifica FOOD; se <= 65%, come até 100% e volta HOME.
-- 3) Nunca executa água e comida ao mesmo tempo.
--============================================================

local function esperarFarmParar()
    while gui.Parent and autoFarmEnabled and running do
        task.wait(0.20)
    end
end

local function esperarAguaCompletar()
    while gui.Parent and autoFarmEnabled and running do
        task.wait(0.20)
    end

    if not autoFarmEnabled then
        return false
    end

    local char = LP.Character
    local water = char and (char:GetAttribute("Water") or 0) or 0
    return water >= FULL_VALUE
end

task.spawn(function()
    while gui.Parent do
        if autoFarmEnabled and not autoFarmBusy and not running then
            local char = LP.Character
            if char then
                local water = char:GetAttribute("Water") or 100
                local food = char:GetAttribute("Food") or 100

                if water <= 70 or food <= 65 then
                    autoFarmBusy = true

                    -- ETAPA 1: ÁGUA. FOOD fica totalmente bloqueado aqui.
                    if water <= 70 and autoFarmEnabled then
                        estado = "AUTO 1/2: ÁGUA • " .. math.floor(water) .. "%"
                        waterTest()
                        esperarAguaCompletar()
                    end

                    -- ETAPA 2: só pode começar depois da água finalizar + voltar.
                    if autoFarmEnabled then
                        char = LP.Character
                        food = char and (char:GetAttribute("Food") or 100) or 100

                        if food <= 65 then
                            estado = "AUTO 2/2: FOOD • " .. math.floor(food) .. "%"
                            grassTest()
                            esperarFarmParar()
                        end
                    end

                    task.wait(0.75)
                    autoFarmBusy = false
                else
                    estado = "AUTO FARM ON • FOME " .. math.floor(food) .. "% • ÁGUA " .. math.floor(water) .. "%"
                end
            end
        end

        task.wait(0.35)
    end
end)

--============================================================
-- VOLTAR MANUAL
--============================================================

local function voltarManual()

	actionToken += 1

	running =
		false

	holdPosition =
		false

	holdCF =
		nil

	pcall(function()

		changeState(
			"ExitEating"
		)

	end)

	pcall(function()

		changeState(
			"ExitDrinking"
		)

	end)

	task.wait(0.1)

	if not homeCF then

		estado =
			"SEM HOME"

		return

	end

	running =
		true

	task.spawn(
		voltarAutomatico
	)

end

--============================================================
-- PARAR FARM
--============================================================

local function parar()

	actionToken += 1

	running =
		false

	holdPosition =
		false

	holdCF =
		nil

	pcall(function()

		changeState(
			"ExitEating"
		)

	end)

	pcall(function()

		changeState(
			"ExitDrinking"
		)

	end)

	local root =
		getRoot()

	root.AssemblyLinearVelocity =
		Vector3.zero

	root.AssemblyAngularVelocity =
		Vector3.zero

	estado =
		"PARADO"

end

--============================================================
-- BOTÕES ESP
--============================================================

espButton.MouseButton1Click:
Connect(function()

	ESPEnabled =
		not ESPEnabled

	espButton.Text =
		"ESP: "
		..
		(
			ESPEnabled
			and
			"ON"
			or
			"OFF"
		)

end)

--============================================================

tracerButton.MouseButton1Click:
Connect(function()

	ShowTracer =
		not ShowTracer

	tracerButton.Text =
		"TRACER: "
		..
		(
			ShowTracer
			and
			"ON"
			or
			"OFF"
		)

end)

--============================================================

highlightButton.MouseButton1Click:
Connect(function()

	ShowHighlight =
		not ShowHighlight

	highlightButton.Text =
		"HIGHLIGHT: "
		..
		(
			ShowHighlight
			and
			"ON"
			or
			"OFF"
		)

end)

--============================================================
-- FARM BUTTONS
--============================================================

waterButton.MouseButton1Click:
Connect(
	waterTest
)

grassButton.MouseButton1Click:
Connect(
	grassTest
)

homeButton.MouseButton1Click:
Connect(
	voltarManual
)

stopButton.MouseButton1Click:
Connect(
	parar
)

--============================================================
-- STATUS
--============================================================

task.spawn(function()

	while gui.Parent do

		status.Text =
			estado

		task.wait(0.15)

	end

end)

--============================================================
-- RESPAWN
--============================================================

LP.CharacterAdded:
Connect(function()

	actionToken += 1

	running =
		false

	holdPosition =
		false

	holdCF =
		nil

	homeCF =
		nil

	estado =
		"RESPAWN"

	canStartText =
		"nil"

end)



--============================================================
-- KILL AURA M1 - 50 STUDS - TODOS NO RAIO
--============================================================
local CollectionService = game:GetService("CollectionService")
local AttackRemote = ReplicatedStorage:WaitForChild("AttackHandlerRemoteEvent")
local KILL_RANGE, ATTACK_INTERVAL = 50, 0.25
killAuraEnabled, lastAttack = false, 0

local function attackAura()
 local char=LP.Character;if not char then return end
 local myRoot=char:FindFirstChild("HumanoidRootPart");if not myRoot then return end
 if char:GetAttribute("IsSpawnProtected") or char:GetAttribute("MovementDisabled") or char:GetAttribute("IsBeingCarried") or char:GetAttribute("IsPouncing") then return end
 local targets={}
 for _,model in ipairs(CollectionService:GetTagged("Animals")) do
  if model~=char and model:IsA("Model") and not model:GetAttribute("IsPouncing") and not model:GetAttribute("IsSpawnProtected") then
   local hum=model:FindFirstChildOfClass("Humanoid");local root=model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
   if hum and hum.Health>0 and root then local d=(root.Position-myRoot.Position).Magnitude;if d<=KILL_RANGE then table.insert(targets,{h=hum,d=d}) end end
  end
 end
 table.sort(targets,function(a,b)return a.d<b.d end)
 for _,v in ipairs(targets) do if not killAuraEnabled then break end;if v.h and v.h.Parent and v.h.Health>0 then pcall(function()AttackRemote:FireServer(v.h)end) end end
end
killAuraButton.MouseButton1Click:Connect(function()killAuraEnabled=not killAuraEnabled;lastAttack=0;killAuraButton.Text="KILL AURA: "..(killAuraEnabled and "ON" or "OFF").." • 50 STUDS" end)
RunService.Heartbeat:Connect(function()if killAuraEnabled and os.clock()-lastAttack>=ATTACK_INTERVAL then lastAttack=os.clock();attackAura() end end)

--============================================================
-- INVISÍVEL / UNDERGROUND V2 - MENOS AGRESSIVO NA REDE
-- Procura CanStart()=="Drink", mas evita forçar CFrame a cada frame.
--============================================================
local undergroundEnabled = false
local undergroundY = nil
local surfaceY = nil
local undergroundToken = 0
local undergroundLastCorrection = 0

local UNDERGROUND_SCAN_MAX = 250
local UNDERGROUND_CORRECTION_INTERVAL = 0.18
local UNDERGROUND_Y_TOLERANCE = 1.25

local function uCanStart()
	local ok, result = pcall(function()
		return Utils.CanEatDrink.CanStart(getChar())
	end)
	return ok and result or nil
end

local function setCameraOffset(value)
	local char = LP.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.CameraOffset = Vector3.new(0, value or 0, 0)
	end
end

disableUnderground = function()
	undergroundToken += 1
	undergroundEnabled = false

	local char = LP.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")

	setCameraOffset(0)

	if root and surfaceY then
		local cf = root.CFrame
		root.CFrame =
			CFrame.new(cf.Position.X, surfaceY, cf.Position.Z)
			* (cf - cf.Position)
	end

	undergroundY = nil
	surfaceY = nil
	undergroundLastCorrection = 0
	undergroundButton.Text = "INVISÍVEL / UNDERGROUND: OFF"
end

enableUnderground = function()
	if undergroundEnabled then return end

	undergroundEnabled = true
	undergroundToken += 1
	local token = undergroundToken

	undergroundButton.Text = "INVISÍVEL: PROCURANDO..."

	task.spawn(function()
		local root = getRoot()
		local original = root.CFrame
		surfaceY = root.Position.Y

		local fixedX = original.Position.X
		local fixedZ = original.Position.Z
		local rotation = original - original.Position
		local foundY = nil

		-- Busca em passos de 1 stud, como a versão que funcionou.
		for offset = 1, UNDERGROUND_SCAN_MAX do
			if not undergroundEnabled or undergroundToken ~= token then
				root.CFrame = original
				return
			end

			local y = surfaceY - offset

			root.CFrame =
				CFrame.new(fixedX, y, fixedZ)
				* rotation

			-- Durante a busca paramos a queda; depois liberamos movimento normal.
			local vel = root.AssemblyLinearVelocity
			root.AssemblyLinearVelocity = Vector3.new(vel.X, 0, vel.Z)

			RunService.Heartbeat:Wait()

			if uCanStart() == "Drink" then
				foundY = root.Position.Y
				break
			end
		end

		if not foundY then
			root.CFrame = original
			undergroundEnabled = false
			surfaceY = nil
			undergroundButton.Text = "INVISÍVEL: CAMADA NÃO ACHADA"
			task.wait(1.2)

			if not undergroundEnabled then
				undergroundButton.Text = "INVISÍVEL / UNDERGROUND: OFF"
			end
			return
		end

		undergroundY = foundY

		-- Usa CameraOffset em vez de somar CFrame da câmera em todo RenderStepped.
		setCameraOffset(surfaceY - undergroundY)

		undergroundLastCorrection = os.clock()
		undergroundButton.Text = "INVISÍVEL / UNDERGROUND: ON"
	end)
end

undergroundButton.MouseButton1Click:Connect(function()
	if undergroundEnabled then
		disableUnderground()
	else
		enableUnderground()
	end
end)

-- Correção limitada. Não disputa o CFrame com o jogo em todo Heartbeat.
RunService.Heartbeat:Connect(function()
	if not undergroundEnabled or not undergroundY then return end

	local now = os.clock()
	if now - undergroundLastCorrection < UNDERGROUND_CORRECTION_INTERVAL then
		return
	end
	undergroundLastCorrection = now

	local char = LP.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local dy = math.abs(root.Position.Y - undergroundY)

	-- Só corrige se o personagem realmente saiu da camada.
	if dy > UNDERGROUND_Y_TOLERANCE then
		local cf = root.CFrame
		root.CFrame =
			CFrame.new(cf.Position.X, undergroundY, cf.Position.Z)
			* (cf - cf.Position)

		-- Mantém movimento horizontal; remove apenas impulso vertical excessivo.
		local vel = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(vel.X, 0, vel.Z)
	end
end)

LP.CharacterAdded:Connect(function()
	undergroundToken += 1
	undergroundEnabled = false
	undergroundY = nil
	surfaceY = nil
	undergroundLastCorrection = 0
	killAuraEnabled = false

	task.defer(function()
		setCameraOffset(0)

		if undergroundButton and undergroundButton.Parent then
			undergroundButton.Text = "INVISÍVEL / UNDERGROUND: OFF"
		end

		if killAuraButton and killAuraButton.Parent then
			killAuraButton.Text = "KILL AURA: OFF • 50 STUDS"
		end
	end)
end)


--============================================================
-- NOVAS FUNÇÕES INTEGRADAS
--============================================================
local PounceRemote=ReplicatedStorage:WaitForChild("SpecialAttackRemoteEvent_PounceAttack")
local LatchRemote=ReplicatedStorage:WaitForChild("LatchedPlayersNotifyRemoteEvent")
local LatchConfig=require(ReplicatedStorage:WaitForChild("AnimalGameSharedCore"):WaitForChild("LatchEscapeConfig"))
local latchedPlayers={}; local escapeThread=nil

local function stopEscape() if escapeThread then task.cancel(escapeThread);escapeThread=nil end end
local function startEscape()
 stopEscape(); if not autoDesgrabEnabled or #latchedPlayers==0 then return end
 escapeThread=task.spawn(function()
  while autoDesgrabEnabled and #latchedPlayers>0 do
   local char=LP.Character;if not char then break end
   local speed=LatchConfig.getRingScaleSpeed(char,latchedPlayers)
   local targetScale=(LatchConfig.MIN_CORRECT_SCALE+LatchConfig.MAX_CORRECT_SCALE)/2
   local timeToHit=(LatchConfig.MAX_SIZE_SCALE-targetScale)/speed
   task.wait(timeToHit)
   if not autoDesgrabEnabled or #latchedPlayers<=0 then break end
   pcall(function() LatchRemote:FireServer() end)
   task.wait(LatchConfig.PAUSE_TIME+LatchConfig.TIME_BEFORE_NEXT_PRESS_AFTER_PAUSE+0.02)
  end
  escapeThread=nil
 end)
end
LatchRemote.OnClientEvent:Connect(function(list)
 if type(list)~="table" then return end; latchedPlayers=list
 if #list==0 then stopEscape() elseif autoDesgrabEnabled then startEscape() end
end)

-- Hitbox manual corrigido:
-- PC: clique esquerdo.
-- Mobile: SOMENTE o botão oficial "NormalAttackButton".
local hitboxLast=0
local hitboxMobileConnection=nil
local hitboxMobileButton=nil

local function getHitboxTarget()
 local char=LP.Character; local myRoot=char and char:FindFirstChild("HumanoidRootPart"); if not myRoot then return nil end
 local best,bestD=nil,hitboxRange
 for _,model in ipairs(CollectionService:GetTagged("Animals")) do
  if model~=char and model:IsA("Model") and not model:GetAttribute("IsSpawnProtected") and not model:GetAttribute("IsPouncing") then
   local hum=model:FindFirstChildOfClass("Humanoid"); local root=model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
   if hum and hum.Health>0 and root then local d=(root.Position-myRoot.Position).Magnitude;if d<=bestD then best,bestD=hum,d end end
  end
 end
 return best
end

local function fireHitboxAttack()
 if not hitboxEnabled or os.clock()-hitboxLast<.20 then return end
 hitboxLast=os.clock()
 local hum=getHitboxTarget()
 if hum then
  pcall(function() AttackRemote:FireServer(hum) end)
 end
end

-- PC: não escuta Touch. Assim tocar/arrastar a tela no mobile não dispara Hitbox.
UIS.InputBegan:Connect(function(input,processed)
 if processed or UIS.TouchEnabled then return end
 if input.UserInputType~=Enum.UserInputType.MouseButton1 then return end
 fireHitboxAttack()
end)

local function connectNormalAttackButton(button)
 if not button or not button:IsA("GuiButton") then return end
 if hitboxMobileButton==button and hitboxMobileConnection then return end

 if hitboxMobileConnection then
  hitboxMobileConnection:Disconnect()
  hitboxMobileConnection=nil
 end

 hitboxMobileButton=button
 hitboxMobileConnection=button.Activated:Connect(function()
  fireHitboxAttack()
 end)
end

local function findNormalAttackButton()
 local button=PlayerGui:FindFirstChild("NormalAttackButton",true)
 if button and button:IsA("GuiButton") then
  connectNormalAttackButton(button)
  return true
 end
 return false
end

-- O React pode montar/recriar os botões depois que o painel já carregou.
if UIS.TouchEnabled then
 task.spawn(function()
  while gui.Parent and not findNormalAttackButton() do
   task.wait(.25)
  end
 end)

 PlayerGui.DescendantAdded:Connect(function(obj)
  if obj.Name=="NormalAttackButton" and obj:IsA("GuiButton") then
   task.defer(function()
    connectNormalAttackButton(obj)
   end)
  end
 end)

 PlayerGui.DescendantRemoving:Connect(function(obj)
  if obj==hitboxMobileButton then
   if hitboxMobileConnection then
    hitboxMobileConnection:Disconnect()
    hitboxMobileConnection=nil
   end
   hitboxMobileButton=nil
  end
 end)
end

-- Auto Grab / Pounce
local function getGrabTarget()
 local char=LP.Character;local myRoot=char and char:FindFirstChild("HumanoidRootPart");if not myRoot then return nil end
 local bestHum,bestRag,bestD=nil,nil,autoGrabRange+.01
 for _,animal in ipairs(CollectionService:GetTagged("Animals")) do
  if animal~=char and animal:IsA("Model") and not animal:GetAttribute("IsSpawnProtected") and not animal:GetAttribute("IsPouncing") and not animal:GetAttribute("IsBeingCarried") and not animal:GetAttribute("IsCarrying") then
   local hum=animal:FindFirstChild("Humanoid");local root=animal:FindFirstChild("HumanoidRootPart");local folder=animal:FindFirstChild("RagdollColliderParts");local rag=folder and folder:FindFirstChild("RagdollColliderRootPart")
   if hum and hum.Health>0 and root and rag then local d=(root.Position-myRoot.Position).Magnitude;if d<=autoGrabRange and d<bestD then bestHum,bestRag,bestD=hum,rag,d end end
  end
 end
 return bestHum,bestRag
end
task.spawn(function()
 while gui.Parent do
  if autoGrabEnabled then
   local char=LP.Character
   if char and not char:GetAttribute("IsPouncing") and not char:GetAttribute("MovementDisabled") and not char:GetAttribute("IsCarrying") and not char:GetAttribute("IsBeingCarried") then
    local hum,rag=getGrabTarget();if hum and rag then pcall(function() PounceRemote:FireServer(hum,rag) end) end
   end
  end
  task.wait(.25)
 end
end)

LP.CharacterAdded:Connect(function()
    if flyEnabled then stopFly() end
end)

-- Velocidade + stamina/oxigênio
RunService.Heartbeat:Connect(function()
 local char=LP.Character;if not char then return end
 local hum=char:FindFirstChildOfClass("Humanoid")
 if hum and speedValue>0 then hum.WalkSpeed=speedValue end
 if infiniteStats then char:SetAttribute("Stamina",100);char:SetAttribute("Oxygen",100);char:SetAttribute("StaminaRanOut",false) end
end)

-- Sempre Dia: trava o relógio visual em 12:00 somente enquanto estiver ON
RunService.RenderStepped:Connect(function()
    if sempreDiaEnabled then
        Lighting.ClockTime = 12
    end
end)

-- sincroniza desgrab quando o toggle muda de estado
RunService.Heartbeat:Connect(function()
 if autoDesgrabEnabled and #latchedPlayers>0 and not escapeThread then startEscape() end
 if not autoDesgrabEnabled and escapeThread then stopEscape() end
end)

print("[SAVANA HUB FINAL V2] tudo OFF | Underground rede leve | RightShift PC | ícone mobile")
