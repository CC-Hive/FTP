-- copied from https://github.com/lyqyd/lnfs-client

local args = {...}

if #args < 3 then
	print("Usage:")
	print(fs.getName(shell.getRunningProgram()).." <host> <share> <path>")
	print("<host>  The name of the computer to connect to.")
	print("        Use i:<id> in place of host to connect by ID.")
	print("<share> The name of the share to connect to on the host.")
	print("<path>  An empty folder on the local machine to mount the share to.")
	return
end

if fs.exists(args[3]) and fs.isDir(args[3]) then
	local list = fs.list(args[3])
	if #list > 0 then
		print("Can only mount to empty directory!")
		return
	end
else
	print("Must mount to empty directory!")
	return
end

local conn = connection.new(args[1], 21)

local response = conn:open(0.5, args[2])
if not response then
	print("Connection to server failed!")
	return
end

local mount = {}
mount.path = shell.resolve(args[3])
if string.sub(mount.path, 1, 1) ~= "/" then mount.path = "/"..mount.path end
mount.mount = {}

mount.mount.list = function(path)
	conn:send("fileList", path)
	local result = conn:listen(0.3)
	if result then
		return result.payload
	else
		return {}
	end
end

mount.mount.exists = function(path)
	conn:send("fileStatus", path)
	local result = conn:listen(0.3)
	if result and result.payload then
		return result.payload.exists
	else
		return false
	end
end

mount.mount.isDir = function(path)
	conn:send("fileStatus", path)
	local result = conn:listen(0.3)
	if result and result.payload then
		return result.payload.isDir
	else
		return false
	end
end

mount.mount.isReadOnly = function(path)
	conn:send("fileStatus", path)
	local result = conn:listen(0.3)
	if result and result.payload then
		return result.payload.isReadOnly
	else
		return false
	end
end

mount.mount.getDrive = function(path)
	return args[1].."."..args[2]
end

mount.mount.getSize = function(path)
	conn:send("fileStatus", path)
	local result = conn:listen(0.3)
	if result and result.payload then
		return result.payload.size
	else
		return false
	end
end

mount.mount.getFreeSpace = function(path)
	conn:send("fileStatus", path)
	local result = conn:listen(0.3)
	if result and result.payload then
		return result.payload.space
	else
		return 0
	end
end

mount.mount.makeDir = function(path)
	conn:send("fileMakeDirectory", path)
end

mount.mount.move = function(origin, destination)
	conn:send("fileMove", {origin = origin, destination = destination})
end

mount.mount.copy = function(origin, destination)
	conn:send("fileCopy", {origin = origin, destination = destination})
end

mount.mount.delete = function(path)
	conn:send("fileDelete", path)
end

mount.mount.find = function(path)
	conn:send("fileFind", path)
	local result = conn:listen(0.3)
	if result and result.payload and result.type == "FI" then
		return result.payload
	else
		return {}
	end
end

mount.mount.get = function(path)
	conn:send("fileQuery", path)
	local received = false
	local data = {}
	repeat
		local pack = conn:listen(0.3)
		if pack and pack.type == "FH" then
			if pack.payload ~= path then
				return false
			end
		elseif pack and pack.type == "FD" then
			for i = 1, #pack.payload do
				data[#data + 1] = pack.payload[i]
			end
		elseif pack and pack.type == "FE" then
			received = true
		end
	until received
	return data
end

mount.mount.put = function(data, path)
	conn:send("fileSend", path)
	local response = conn:listen(0.3)
	if response and response.type == "FR" then
		conn:send("fileHeader", path)
		conn:send("fileData", data)
		conn:send("fileEnd", "eof")
	end
end

table.insert(LyqydOS.fs.mounts, mount)

