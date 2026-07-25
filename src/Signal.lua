--!nonstrict
-- Sable :: Signal
-- Minimal, allocation-light signal. Handlers are pcall'd so one bad callback
-- can never take the menu down mid-frame.

local Signal = {}
Signal.__index = Signal

local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false

	local handlers = self._signal._handlers
	for i = #handlers, 1, -1 do
		if handlers[i] == self then
			table.remove(handlers, i)
			break
		end
	end

	self._fn = nil
	self._signal = nil
end

Connection.disconnect = Connection.Disconnect
Connection.Destroy = Connection.Disconnect

function Signal.new(name)
	return setmetatable({
		_handlers = {},
		_name = name or "Signal",
	}, Signal)
end

function Signal:Connect(fn)
	assert(type(fn) == "function", "[Sable] Signal:Connect expects a function")

	local connection = setmetatable({
		Connected = true,
		_fn = fn,
		_signal = self,
	}, Connection)

	table.insert(self._handlers, connection)
	return connection
end

Signal.connect = Signal.Connect

function Signal:Once(fn)
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		fn(...)
	end)
	return connection
end

function Signal:Fire(...)
	-- Snapshot so a handler disconnecting (or connecting) mid-fire is safe.
	local snapshot = table.clone(self._handlers)
	for i = 1, #snapshot do
		local connection = snapshot[i]
		if connection.Connected then
			local ok, err = pcall(connection._fn, ...)
			if not ok then
				warn(("[Sable] %s handler error: %s"):format(self._name, tostring(err)))
			end
		end
	end
end

function Signal:DisconnectAll()
	local snapshot = table.clone(self._handlers)
	for i = 1, #snapshot do
		snapshot[i]:Disconnect()
	end
	table.clear(self._handlers)
end

Signal.Destroy = Signal.DisconnectAll

return Signal
