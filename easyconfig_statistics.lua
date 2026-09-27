#!/usr/bin/lua
local fs = require "nixio.fs"
local json = require "luci.jsonc"

local filename = "/tmp/easyconfig_statistics.json"

local MAC       = arg[1]
local IFNAME    = arg[2]
local TX        = tonumber(arg[3]) or 0
local RX        = tonumber(arg[4]) or 0
local CONNECTED = tonumber(arg[5]) or 0
local DHCPNAME  = arg[6]
local TYPE      = tonumber(arg[7]) or 0

if not MAC or not IFNAME or not arg[7] then
    print("Usage: easyconfig_statistics.lua <MAC> <IFNAME> <TX> <RX> <CONNECTED> <DHCPNAME> <TYPE>")
    os.exit(1)
end

-- compatibility with old scripts
MAC = MAC:gsub(":", "_")

local ts = os.date("*t")
local day = string.format("%04d%02d%02d", ts.year, ts.month, ts.day)
local hour = string.format("%02d", ts.hour)
local ts_now = string.format("%04d%02d%02d%02d%02d", ts.year, ts.month, ts.day, ts.hour, ts.min)

local db = {}
local content = fs.readfile(filename)
if content and content ~= "" then
    local parser = json.new()
    if parser:parse(content) then
        db = parser:get() or {}
    end
end

if IFNAME == "init" then
    for key1, val1 in pairs(db) do
        if type(val1) == "table" then
            for key2, val2 in pairs(val1) do
                if type(val2) == "table" then
                    val2.last_tx = 0
                    val2.last_rx = 0
                end
            end
        end
    end
    fs.writefile(filename, json.stringify(db))
    os.exit(0)
end

if IFNAME == "delete" then
    if db[MAC] then
        db[MAC] = nil
        fs.writefile(filename, json.stringify(db))
    end
    os.exit(0)
end

if type(db[MAC]) ~= "table" then
    db[MAC] = { first_seen = ts_now }
end

if DHCPNAME and DHCPNAME ~= "" then
    db[MAC].dhcpname = DHCPNAME
end

db[MAC].type = TYPE

if type(db[MAC][IFNAME]) ~= "table" then
    db[MAC][IFNAME] = { last_tx = 0, last_rx = 0, first_seen = ts_now }
end

local last_tx = tonumber(db[MAC][IFNAME].last_tx) or 0
local last_rx = tonumber(db[MAC][IFNAME].last_rx) or 0

if type(db[MAC][IFNAME][day]) ~= "table" then
    db[MAC][IFNAME][day] = { total_tx = 0, total_rx = 0, hours = {} }
end

if type(db[MAC][IFNAME][day].hours) ~= "table" then
    db[MAC][IFNAME][day].hours = {}
end

local total_tx = tonumber(db[MAC][IFNAME][day].total_tx) or 0
local total_rx = tonumber(db[MAC][IFNAME][day].total_rx) or 0

local dtx = TX - last_tx
if dtx < 0 then dtx = TX end

local drx = RX - last_rx
if drx < 0 then drx = RX end

if CONNECTED <= 60 then
    dtx = TX
    drx = RX
end

db[MAC][IFNAME][day].total_tx = total_tx + dtx
db[MAC][IFNAME][day].total_rx = total_rx + drx

if dtx > 0 or drx > 0 then
    if type(db[MAC][IFNAME][day].hours[hour]) ~= "table" then
        db[MAC][IFNAME][day].hours[hour] = { total_tx = 0, total_rx = 0 }
    end
    local hour_tx = tonumber(db[MAC][IFNAME][day].hours[hour].total_tx) or 0
    local hour_rx = tonumber(db[MAC][IFNAME][day].hours[hour].total_rx) or 0
    db[MAC][IFNAME][day].hours[hour].total_tx = hour_tx + dtx
    db[MAC][IFNAME][day].hours[hour].total_rx = hour_rx + drx
end

db[MAC][IFNAME].last_tx = TX
db[MAC][IFNAME].last_rx = RX
db[MAC][IFNAME].last_seen = ts_now
db[MAC].last_seen = ts_now

fs.writefile(filename, json.stringify(db))
os.exit(0)
