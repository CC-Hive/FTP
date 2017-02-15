local config = {
	lyqydnet = {
		listenPort = 21,
	},

	shares = {
		["public"] = {
			path = "/share",
			public = true,
		},
	},
}

if not configuration then if shell.resolveProgram("configuration") then os.loadAPI(shell.resolveProgram("configuration")) elseif fs.exists("usr/apis/configuration") then os.loadAPI("usr/apis/configuration") else error("Could not load configuration API!") end end

local function log(level, message)
	print(level..": "..message)
	os.queueEvent("service_message", level, process and process.id() or multishell and multishell.getCurrent() or 0, message)
end

local translate = {
	query = "SQ",
	response = "SR",
	data = "SP",
	done = "SB",
	close = "SC",
	fileQuery = "FQ",
	fileSend = "FS",
	fileResponse = "FR",
	fileHeader = "FH",
	fileData = "FD",
	fileEnd = "FE",
	fileFind = "FF",
	fileCopy = "FC",
	fileDelete = "FM",
	fileMove = "FV",
	fileMakeDirectory = "FK",
	fileList = "FL",
	fileInformation = "FI",
	fileStatus = "FZ",
	SQ = "query",
	SR = "response",
	SP = "data",
	SB = "done",
	SC = "close",
	FQ = "fileQuery",
	FS = "fileSend",
	FR = "fileResponse",
	FH = "fileHeader",
	FD = "fileData",
	FE = "fileEnd",
	FF = "fileFind",
	FC = "fileCopy",
	FM = "fileDelete",
	FV = "fileMove",
	FK = "fileMakeDirectory",
	FL = "fileList",
	FI = "fileInformation",
	FZ = "fileStatus",
}

local currentDir = string.match(shell.getRunningProgram(), "^(.*)"..fs.getName(shell.getRunningProgram()).."$")

config, err = configuration.load(fs.combine(currentDir, "lnfsd.conf"))
if not config then
	if err == "not a file" then
		configuration.save(fs.combine(currentDir, "lnfsd.conf"), config)
		log("info", "Using default configuration file")
	else
		log("error", err)
		return
	end
end

local connections = {}

while true do
	local pack, conn = connection.listen(config.lyqydnet.listenPort)
	local pType, message = translate[pack.type], pack.payload
	if connections[conn] and connections[conn].status == "open" then
		--handle most things
		if pType == "fileList" then
			local path = fs.combine(config.shares[connections[conn].share].path, message)
			if fs.exists(path) and fs.isDir(path) then
				conn:send("fileInformation", fs.list(path))
			end
		elseif pType == "fileStatus" then
			local path = fs.combine(config.shares[connections[conn].share].path, message)
			local response = {file = message, exists = false}
			if fs.exists(path) then
				response.exists = true
				response.isDir = fs.isDir(path)
				response.isReadOnly = fs.isReadOnly(path)
				response.size = fs.getSize(path)
				response.space = fs.getFreeSpace(path)
			end
			conn:send("fileInformation", response)
		elseif pType == "fileMove" or pType == "fileCopy" then
			local func = pType == "fileMove" and fs.move or fs.copy
			local originPath = fs.combine(config.shares[connections[conn].share].path, message.origin)
			local destinationPath = fs.combine(config.shares[connections[conn].share].path, message.destination)
			func(originPath, destinationPath)
			conn:send("done", "ok")
		elseif pType == "fileDelete" or pType == "fileMakeDirectory" then
			local func = pType == "fileDelete" and fs.delete or fs.makeDir
			local path = fs.combine(config.shares[connections[conn].share].path, message)
			func(path)
			conn:send("done", "ok")
		elseif pType == "fileFind" then
			if fs.find then
				local path = fs.combine(config.shares[connections[conn].share].path, message)
				conn:send("fileInformation", fs.find(path))
			else
				conn:send("done", "too old")
			end
		elseif pType == "fileSend" then
			--client wants to send us a file.
			if connections[conn].state == "" then
				local path = fs.combine(config.shares[connections[conn].share].path, message)
				if (fs.exists(path) and not fs.isDir(path)) or not fs.exists(path) then
					conn:send("fileResponse", "ok")
					connections[conn].state = "receive"
					connections[conn].rxpath = path
					connections[conn].rxdata = {}
				else
					conn:send("done", "ok")
				end
			else
				conn:send("done", "ok")
			end
		elseif pType == "fileHeader" then
			conn:send("done", "ok")
		elseif pType == "fileData" then
			if connections[conn].state == "receive" then
				for i = 1, #message do
					connections[conn].rxdata[#connections[conn].rxdata + 1] = message[i]
				end
			end
			conn:send("done", "ok")
		elseif pType == "fileEnd" then
			if connections[conn].state == "receive" then
				local handle = io.open(connections[conn].rxpath, "wb")
				if handle then
					for i = 1, #connections[conn].rxdata do
						handle:write(connections[conn].rxdata[i])
					end
					handle:close()
					conn:send("done", "ok")
					connections[conn].state = ""
					connections[conn].rxpath = nil
					connections[conn].rxdata = nil
				else
					conn:send("done", "failed to write file")
				end
			else
				conn:send("done", "ignored")
			end
		elseif pType == "fileQuery" then
			if connections[conn].state == "" then
				local path = fs.combine(config.shares[connections[conn].share].path, message)
				if fs.exists(path) then
					local handle = io.open(path, "rb")
					if handle then
						conn:send("fileHeader", message)
						local data = {}
						local num = handle:read()
						while num do
							data[#data + 1] = num
							num = handle:read()
						end
						conn:send("fileData", data)
						conn:send("fileEnd", "eof")
						handle:close()
					else
						conn:send("fileHeader", "FileOpenFailure")
					end
				else
					conn:send("fileHeader", "FileNotFound")
				end
			end
		elseif pType == "close" then
			connections[conn] = nil
			log("info", "client disconnected: "..conn.remote)
			conn:send("close", "ok")
		elseif pType == "query" then
			--connection being re-opened by client, reset status.
			if config.shares[message] then
				log("info", "client connected:"..conn.remote)
				conn:send("response", "ok")
				connections[conn] = {
					status = "open",
					state = "",
					share = message,
				}
			else
				conn:send("close", "access denied")
			end
		end
	else
		--no currently established connection.
		if pType == "query" then
			if config.shares[message] then
				--requested share exists
				if config.shares[message].public then
					log("info", "client connected: "..conn.remote)
					conn:send("response", "ok")
					connections[conn] = {
						status = "open",
						state = "",
						share = message,
					}
				else
					conn:send("close", "access denied")
				end
			end
		end
	end
end

