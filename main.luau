local net = require("@lune/net")
local process = require("@lune/process")
local stdio = require("@lune/stdio")
local fs = require("@lune/fs")
local slaxml = require("./slaxml")

local HOST = "192.168.2.124"
local PORT = 64989
local INPUT_CODE
local INPUT_FILEPATH
local JOB_TO_CREATE
local JOB_TO_RUN_ON

for i, arg in process.args do
    local host = arg:match("^%-%-host=(.+)")
    if host then
        HOST = host
        continue
    end

    local port = arg:match("^%-%-port=(.+)")
    if port then
        PORT = tonumber(port)
        if not PORT then
            stdio.ewrite("failed to convert port to number\n")
            process.exit(1)
        end
        continue
    end

    local code = arg:match("^%-%-code=(.+)")
    if code then
        INPUT_CODE = code
        continue
    end

    local script = arg:match("^%-%-script=(.+)")
    if script then
        INPUT_FILEPATH = script
        continue
    end

    local createjob = arg:match("^%-%-createjob=(.+)")
    if createjob then
        JOB_TO_CREATE = createjob
        continue
    end

    local job = arg:match("^%-%-job=(.+)")
    if job then
        JOB_TO_RUN_ON = job
        continue
    end

    stdio.ewrite("unhandled argument '")
    stdio.ewrite(arg)
    stdio.ewrite("'\n")
    process.exit(1)
end

local code

if INPUT_CODE then
    code = INPUT_CODE
    assert(not INPUT_FILEPATH, "you cannot provide both --code and --script")
elseif INPUT_FILEPATH then
    if INPUT_FILEPATH:match("^/") or INPUT_FILEPATH:match("%.%.") then
        stdio.ewrite("illegal filepath\n")
        process.exit(1)
    end
    code = fs.readFile(INPUT_FILEPATH)
    assert(not INPUT_FILEPATH, "you cannot provide both --code and --script")
end

local function byte_ify(str)
    return (str:gsub('.', function(char)
        local res = {'\\'}
        local byte = char:byte()

        if byte < 100 then
            res[#res + 1] = '0'
        end
        if byte < 10 then
            res[#res + 1] = '0'
        end

        res[#res + 1] = byte

        return table.concat(res)
    end))
end


-- print("connecting...")

local conn = net.tcp.connect(HOST, PORT)

-- print("made connection")

local body = [[POST / HTTP/1.1
Host: %s:%d
Accept: text/xml,
Cache-Control: no-cache,
Pragma: no-cache,
SOAPAction: Execute

<?xml version="1.0" encoding="UTF - 8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:SOAP-ENC="http://schemas.xmlsoap.org/soap/encoding/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:ns2="http://roblox.com/RCCServiceSoap" xmlns:ns1="http://roblox.com/" xmlns:ns3="http://roblox.com/RCCServiceSoap12"><SOAP-ENV:Body>
%s
</SOAP-ENV:Body></SOAP-ENV:Envelope>
]]

local script_template = [[
-- local logs = {}
-- game:GetService("LogService").MessageOut:Connect(function(message)
--     logs[#logs + 1] = message
-- end)

-- return game:GetService("ThumbnailGenerator"):Click("PNG", 4000, 2000, true)
local chunk, err = loadstring("%s")
if not chunk then
    error("invalid code: " .. tostring(err))
end

local ret = {xpcall(chunk, function(err)
    warn("ERROR:" .. tostring(err))
end)}
table.remove(ret, 1)

local loghistory = game:GetService("LogService"):GetLogHistory()
local logs = {}

for i,v in next, loghistory do
    logs[i] = assert(v.message)
end

return table.concat(logs, '\n'), unpack(ret)
]]

local payloads = {
    runOnJob = function(job, code)
        return ([[<ns1:Execute>
            <ns1:jobID>%s</ns1:jobID>
            <ns1:script>
                <ns1:name>input</ns1:name>
                <ns1:script>
                    %s
                </ns1:script>
                <ns1:arguments>
                </ns1:arguments>
            </ns1:script>
        </ns1:Execute>
        ]]):format(job, script_template:format(byte_ify(code)))
    end,
    createJobAndRun = function(job, code)
        return ([[<ns1:OpenJobEx>
            <ns1:job>
                <ns1:id>%s</ns1:id>
                <ns1:expirationInSeconds>9999</ns1:expirationInSeconds>
                <ns1:category>0</ns1:category>
                <ns1:cores>1</ns1:cores>
            </ns1:job>
            <ns1:script>
                <ns1:name>input</ns1:name>
                <ns1:script>
                    %s
                </ns1:script>
            <ns1:arguments>
            </ns1:arguments>
            </ns1:script>
        </ns1:OpenJobEx>]]):format(job, script_template:format(byte_ify(code)))
    end
}

local function nextJob()
    return "sudsJob_" .. os.clock()
end

if JOB_TO_CREATE or not JOB_TO_RUN_ON then
    body = body:format(HOST, PORT, payloads.createJobAndRun(JOB_TO_CREATE or nextJob(), code))
else
    body = body:format(HOST, PORT, payloads.runOnJob(JOB_TO_RUN_ON, code))
end

-- print(body)
conn:write(body)

-- print("wrote")

local responset = {}
while true do
    local response = conn:read()
    if #response > 0 then
        responset[#responset + 1] = response
    else
        break
    end
end

local response = table.concat(responset)

-- print("read response")

conn:close()

-- print("RESPONSE START")
-- print((response):gsub('\r', function()return "\\r" end):gsub('\n', function()return "\\n" end))
-- print("RESPONSE END")

-- if true then
--     slaxml:parse(response)
--     return
-- end

local response_body = response:match("\r\n\r\n(.+)")

-- print("parsing xml...")

local metatable = {
    __index = function(self, key)
        if type(key) == "string" then
            for k,v in self do
                if v.name == key then
                    return v
                end
            end
            return nil
        end

        return nil
    end
}

local root = setmetatable({}, metatable)
local parentstack = table.create(100)
parentstack[1] = root
local parser = slaxml:parser{
    startElement = function(name,nsURI,nsPrefix)
        local obj = setmetatable({
            name = name
        }, metatable)
        local parent = parentstack[#parentstack]
        parent[#parent + 1] = obj
        parentstack[#parentstack + 1] = obj
    end, -- When "<foo" or <x:foo is seen
    attribute    = function(name,value,nsURI,nsPrefix) end, -- attribute found on current element
    closeElement = function(name,nsURI)
        parentstack[#parentstack] = nil
    end, -- When "</foo>" or </x:foo> or "/>" is seen
    text         = function(text,cdata)
        parentstack[#parentstack].text = text
    end, -- text and CDATA nodes (cdata is true for cdata nodes)
    comment      = function(content)                   end, -- comments
    pi           = function(target,content)            end, -- processing instructions e.g. "<?yes mon?>"
}

-- Ignore whitespace-only text nodes and strip leading/trailing whitespace from text
-- (does not strip leading/trailing whitespace from CDATA)
parser:parse(response_body, {stripWhitespace=true})

local envelopebody = root.Envelope.Body
if envelopebody.Fault then
    local a = envelopebody.Fault
    a = a and a.faultstring
    a = a and a.text or "unknown error"
    print(a)
else
    print(envelopebody.ExecuteResponse or envelopebody.OpenJobExResponse)
end
