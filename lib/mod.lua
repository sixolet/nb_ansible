local mod = require 'core/mods'
local music = require 'lib/musicutil'
local voice = require 'lib/voice'

if note_players == nil then
    note_players = {}
end

local function freq_to_note_num_float(freq)
    local reference = music.note_num_to_freq(60)
    local ratio = freq/reference
    return 60 + 12*math.log(ratio)/math.log(2)
end

local freq_params = {
    "nb_ansible_freq_1",
    "nb_ansible_freq_2",
    "nb_ansible_freq_3",
    "nb_ansible_freq_4",
}

local function add_player(idx)
    local player = {
        ext = "_"..idx,
        count = 0,
        tuning = false,
    }

    function player:add_params()
        params:add_group("nb_ansible_"..self.ext, "ansible "..idx, 3)
        params:add_control("nb_ansible_portomento"..self.ext, "portomento", controlspec.new(0.0, 1, 'taper', 0, 0.0, "s"))
        params:set_action("nb_ansible_portomento"..self.ext, function(p)
            crow.ii.ansible.cv_slew(idx, math.floor(p*1000))
        end)
        params:add_control("nb_ansible_freq"..self.ext, "tuned to", controlspec.new(20, 4000, 'exp', 0, 440, 'Hz', 0.0003))
        params:add_binary("nb_ansible_tune"..self.ext, "tune", "trigger")
        params:set_action("nb_ansible_tune"..self.ext, function()
            self:tune()
        end)
        params:hide("nb_ansible_"..self.ext)
    end

    function player:note_on(note, vel)
        if self.tuning then return end
        -- I have zero idea why I have to add 50 cents to the tuning for it to sound right.
        -- But I do. WTF.
        local halfsteps = note - freq_to_note_num_float(params:get("nb_ansible_freq"..self.ext))
        local v8 = halfsteps/12
        crow.ii.ansible.trigger(idx, 1)
        crow.ii.ansible.cv(idx, v8)
        self.count = self.count + 1
    end

    function player:note_off(note)
        if self.tuning then return end
        self.count = self.count - 1
        if self.count <= 0 then
            self.count = 0
            crow.ii.ansible.trigger(idx, 0)
        end
    end

    function player:set_slew(s)
        params:set("nb_ansible_portomento"..self.ext, s)
    end

    function player:describe(note)
        return {
            name = "ansible "..idx,
            supports_bend = false,
            supports_slew = true,
            modulate_description = "unsupported",
        }
    end

    function player:active()
        params:show("nb_ansible_"..self.ext)
        _menu.rebuild_params()
    end

    function player:inactive()
        params:hide("nb_ansible_"..self.ext)
        _menu.rebuild_params()
    end

    function player:tune()
        print("OMG TUNING")
        self.tuning = true
        crow.ii.ansible.cv(idx, 0)
        crow.ii.ansible.trigger(idx, 1)

        local p = poll.set("pitch_in_l")
        p.callback = function(f) 
            print("in > "..string.format("%.2f",f))
            params:set("nb_ansible_freq"..self.ext, f)
        end
        p.time = 0.25
        p:start()
        clock.run(function()
             clock.sleep(10)
             p:stop()
             crow.ii.ansible.trigger(idx, 0)
             -- crow.input[1].mode('none')
             clock.sleep(0.2)
             self.tuning = false
        end)
    end
    note_players["ansible "..idx] = player
end

local function add_poly_player()
    local player = {
        alloc = voice.new(4, voice.MODE_LRU),
        voices = 4,
        notes = {},
    }

    function player:add_params()
        params:add_group("nb_ansible_poly", "ansible poly", 3)
        params:add_number("nb_ansible_poly_voices", "voices", 2, 4, 4)
        params:set_action("nb_ansible_poly_voices", function(n)
            self.voices = n
            self:stop_all()
        end)
        params:add_control("nb_ansible_portomento_poly", "portomento", controlspec.new(0.0, 1, 'taper', 0, 0.0, "s"))
        params:set_action("nb_ansible_portomento_poly", function(p)
            for idx = 1,params:get("nb_ansible_poly_voices") do
                crow.ii.ansible.cv_slew(idx, math.floor(p*1000))
            end
        end)
        params:add_binary("nb_ansible_tune_poly", "tune", "trigger")
        params:set_action("nb_ansible_tune_poly", function()
            clock.run(function()
                for i = 1,params:get("nb_ansible_poly_voices") do
                    local p = note_players["ansible "..i]
                    p:tune()
                    clock.sleep(12)
                end
            end)
        end)
        params:hide("nb_ansible_poly")
    end

    function player:active()
        params:show("nb_ansible_poly")
        _menu.rebuild_params()
    end

    function player:inactive()
        params:hide("nb_ansible_poly")
        _menu.rebuild_params()
    end

    function player:note_on(note, vel)
        local slot = self.notes[note]
        if slot == nil then
            slot = self.alloc:get()
            slot.count = 1
        end
        slot.on_release = function()
            crow.ii.ansible.trigger(slot.id, 0)
        end
        self.notes[note] = slot
        local halfsteps = note - freq_to_note_num_float(params:get(freq_params[slot.id]))
        local v8 = halfsteps/12
        -- print("v8", v8)
        crow.ii.ansible.cv(slot.id, v8)
        crow.ii.ansible.trigger(slot.id, 1)
    end

    function player:pitch_bend(note, val)
        local slot = self.notes[note]
        if slot ~= nil then
            local halfsteps = note + val - freq_to_note_num_float(params:get(freq_params[slot.id]))
            local v8 = halfsteps/12
            crow.ii.ansible.cv(slot.id, v8)
        end
    end

    function player:note_off(note)
        local slot = self.notes[note]
        if slot ~= nil then
            self.alloc:release(slot)
        end
        self.notes[note] = nil
    end

    function player:describe(note)
        return {
            name = "ansible poly",
            supports_bend = true,
            supports_slew = true,
            note_mod_targets = {},
            modulate_description = "unsupported",
        }
    end

    function player:stop_all()
        crow.ii.ansible.trigger(0, 0)
        self.notes = {}
        self.alloc = voice.new(self.voices, voice.MODE_LRU)
    end

    note_players["ansible poly"] = player
end

mod.hook.register("script_pre_init", "nb ansible pre init", function()
    for i=1,4 do
        add_player(i)
    end
    print("dooo dooooo")
    add_poly_player()
end)