local Request = require"resty.request"
local Response = require "resty.response"
local Router = require"resty.router"
local Admin = require"resty.admin"
local utils = require"resty.utils"
local encode = require "cjson.safe".encode
local string_format = string.format
local ngx_header = ngx.header
local ngx_print = ngx.print
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_var = ngx.var
local table = table

local version = '1.1'

local function warn(...)
    return ngx_log(ngx.ERR, string_format(...))
end

local function split_path(p)
    local res = {}
    for k in p:gmatch("([^/\\]+)") do
        table.insert(res, k)
    end
    return res
end

local app = Router:class{
    model_folder_name = 'models',
    controller_folder_name = 'controllers',
    admin_folder_name = 'admin',
}
function app.new(cls, self)
    self = self or {}
    Router.class(cls, self) -- copy cls to self
    Router.new(cls, self) -- setup router
    if not self.name then
        warn("creating an app instance without a name means you can't use `collect` method")
    end
    return self
end
function app.handle_error(self, msg, status)
    ngx_log(ngx_ERR, msg)
    ngx.status = status or 500
    ngx_header.content_type = 'application/json; charset=utf-8'
    ngx_header.cache_control = 'no-store' -- disable cache
    return ngx.print(encode(msg) or '"server error"')
end
function app.exec(self)
    local uri = ngx_var.document_uri
    local method = ngx_var.request_method
    local controller, captured_or_err, status = self:match(uri)
    if not controller then
        return self:handle_error(captured_or_err, status)
    end
    local request = Request:new{
        kwargs = captured_or_err, 
        method = method, 
        uri = uri,
    }
    local response, status_or_err, status = controller(request)
    if not response  then
        return self:handle_error(status_or_err, status)
    end
    local res, err = request:save_cookies()
    if not res then
        return self:handle_error(err)
    end
    local t = type(response)
    if t == 'table' then
        response, err = encode(response)
        if not response then
            return self:handle_error(err)
        end
        ngx.status = status_or_err or 200
        ngx_header.content_type = 'application/json; charset=utf-8'
        ngx_header.cache_control = 'no-store' -- ** disable cache
        return ngx_print(response)
    elseif t == 'string' then
        ngx.status = status_or_err or 200
        ngx_header.content_type = 'text/html; charset=utf-8'
        return ngx_print(response)
    elseif t == 'function' then
        response, err = response() 
        if not response then
            return self:handle_error(err)
        end
        return response
    else
        return self:handle_error('unrecognized response type: '..t)
    end
end
function app.collect(self)
    assert(self.name, 'this method requires `name` defined')
    self:collect_models()
    self:collect_controllers()
    self:collect_admins()
    local admin_controllers = Admin:make_controllers{
        admins = self.admins,
        folder = self.folder,
        User = self.models.user,
    }
    for i, e in ipairs(admin_controllers) do
        self:add(e)
    end
    return self
end
local function collect_modules(path, callback)
    for i, file in ipairs(utils.files(path)) do    
        local path_table = split_path(file)
        local n = #path_table
        local file_name = path_table[n] or ''
        local folder_name = path_table[n-1] or ''
        if  file_name:sub(-4, -1) ~= '.lua' then
            warn('%s is ignored: not a lua file', file)
        elseif folder_name:sub(1,1) == '!' then
            warn('%s is ignored: folder name starts with `!`', file)
        elseif file_name:sub(1,1) == '!' then
            warn('%s is ignored: file name starts with `!`', file)
        else    
            path_table[n] = file_name:sub(1, -5) 
            local require_path = table.concat(path_table, '.') 
            local ok, m = pcall(require, require_path)
            if not ok then
                warn('loading module %s failed: %s', require_path, m)
            else
                -- ['app', 'models', 'foo'] => ['foo']
                -- ['app', 'controllers', 'foo', 'bar'] => ['foo', 'bar']
                callback(m, utils.slice(path_table, 3))
            end
        end
    end
end
function app.collect_models(self)
    self.models = {}
    local function callback(model, path_table)
        if type(model) == 'table' and type(model.fields) == 'table' then
            if not model.table_name then
                model.table_name = table.concat(path_table, '_')
            end
            model.path_table = path_table
            self.models[model.table_name] = model
        else
            warn('%s is ignored: not a model (type:%s)', table.concat(path_table, '/'), type(model))
        end
    end
    local path = string_format('%s/%s', self.name, self.model_folder_name)
    collect_modules(path, callback)
end
function app.collect_controllers(self)
    local function callback(c, path_table)
        local url =  '/'..table.concat(path_table, '/')
        if utils.callable(c) then 
            -- one file one controller, extract url from path
            -- {'app', 'controllers', 'foo', 'bar'} => /foo/bar
            self:add{url, c}
        elseif type(c) == 'table' then
            if type(c.path or c[1]) == 'string' then 
                -- one file one controller, standard route object
                self:check_builder(c)
                self:add{c.path or c[1], c.controller or c[2], c.methods or c[3]}
            else
                -- try to fit it to multiple methods controller
                local ok, err = pcall(self.check_controller, self, c)
                if ok then
                    self:add{url, c}
                elseif type(c[1]) == 'table' then 
                    -- try to fit it to a controller group
                    for i, e in ipairs(c) do
                        self:check_builder(e)
                        local p = e.path or e[1] 
                        if p == '' then 
                            -- main url of this group
                            e.path = url
                        elseif p:sub(1, 1) ~= '/' then 
                            -- implicit prefix 
                            e.path = url..'/'..p
                        end
                        self:add{e.path or e[1], e.controller or e[2], e.methods or e[3]}
                    end
                else
                    warn('%s is ignored: no controller returned (type:%s)', table.concat(path_table, '/'), type(c))
                end
            end
        else
            warn('%s is ignored: no controller returned (type:%s)', table.concat(path_table, '/'), type(c))
        end
    end
    local path = string_format('%s/%s', self.name, self.controller_folder_name)
    collect_modules(path, callback)
end
function app.find_model_by_path(self, key)
    for name, model in pairs(self.models) do
        if table.concat(model.path_table, '/') == key then
            return model
        end
    end
end
local function to_admin_folder(model_folder, path_table, admin)
    local cd = model_folder
    local n = #path_table
    for i=1, n-1 do
        local folder_name = path_table[i]
        local folder_name_exists = false
        for i, folder in ipairs(cd.folders) do
            if folder.name == folder_name then
                folder_name_exists = true
                cd = folder
                break
            end
        end
        if not folder_name_exists then
            local new_folder = {name=folder_name, files=utils.array(), folders=utils.array()}
            table.insert(cd.folders, new_folder)
            cd = new_folder
        end
    end
    local data = utils.jcopy(admin) -- delete unserialiable values
    table.insert(cd.files, {name=path_table[n], data=data})
end
function app.collect_admins(self)
    self.admins = {}
    self.folder = {name='models', files=utils.array(), folders=utils.array()}
    local function callback(admin_attrs, path_table)
        local key = table.concat(path_table, '/')
        local model = self:find_model_by_path(key)
        if not model then
            warn('admin %s has no corresponding model', key)
        end
        admin_attrs.model = model
        local admin = Admin:new(admin_attrs)
        self.admins['/'..key] = admin
        to_admin_folder(self.folder, path_table, admin)
    end
    local path = string_format('%s/%s', self.name, self.admin_folder_name)
    collect_modules(path, callback)
end

return app
    