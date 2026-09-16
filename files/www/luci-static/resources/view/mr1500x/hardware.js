'use strict';
'require view';
'require form';
'require uci';

/*
 * MR1500X / MR60Xv2 — LEDs & Buttons.
 *
 * This page exists because the stock LuCI LED page cannot work on this device.
 * That page enumerates /sys/class/leds over ubus (luci.getLEDs), and this
 * kernel is built with `# CONFIG_NEW_LEDS is not set` — there is no LED class
 * to enumerate and no module can add one. (The stock menu entry hides itself:
 * it depends on fs:/sys/class/leds being a directory.) The hardware here is a
 * dual-color GPIO LED plus switch-ASIC port LEDs, driven by /etc/init.d/led.
 *
 * Buttons have no stock LuCI page at all. The single physical button is a
 * polled GPIO surfaced as hotplug uevents (no input subsystem in this kernel),
 * handled by /etc/rc.button/reset.
 *
 * Both read the same uci config, `system`, so LuCI's normal Save & Apply
 * applies them: /etc/config/ucitrack maps system -> /etc/init.d/led reload.
 *
 * The hardware map (pins, which are safe to drive, why) is in the header
 * comment of /etc/init.d/led.
 */

return view.extend({
	load: function() {
		return uci.load('system');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('system', _('LEDs & Buttons'),
			_('Front-panel indicators and the physical button on this device. These are driven by board-specific code rather than by the Linux LED and input subsystems, which this kernel does not have.'));

		/* ---- status LED (one dual-color LED on two GPIOs) ---- */

		s = m.section(form.TableSection, 'led', _('Status LED'),
			_('The status LED is a single two-color LED: it can show green or orange, but never both.'));
		s.anonymous = true;
		s.addremove = false;
		s.filter = function(section_id) {
			return uci.get('system', section_id, 'interface') == 'status';
		};

		o = s.option(form.ListValue, 'trigger', _('Behaviour'));
		o.value('auto', _('Leave alone'));
		o.value('on', _('On'));
		o.value('off', _('Off'));
		o.value('timer', _('Blink'));
		o.default = 'on';

		o = s.option(form.ListValue, 'color', _('Color'));
		o.value('green', _('Green'));
		o.value('orange', _('Orange'));
		o.default = 'green';
		o.depends('trigger', 'on');
		o.depends('trigger', 'timer');

		o = s.option(form.Value, 'delayon', _('On time'), _('milliseconds'));
		o.datatype = 'uinteger';
		o.placeholder = '500';
		o.depends('trigger', 'timer');

		o = s.option(form.Value, 'delayoff', _('Off time'), _('milliseconds'));
		o.datatype = 'uinteger';
		o.placeholder = '500';
		o.depends('trigger', 'timer');

		/* ---- WPS LED: only when configured ----
		 * The board this was built on does not fit this LED, so no uci section
		 * ships and nothing is shown. Other variants in the family may have it:
		 * add a `config led` with interface 'wps' and the control appears here.
		 */

		if (uci.sections('system', 'led').filter(function(sec) {
			return sec.interface == 'wps';
		}).length > 0) {
			s = m.section(form.TableSection, 'led', _('WPS LED'),
				_('Driven directly on GPIO 57. Its polarity has never been confirmed by eye — if On and Off come out swapped, that is why.'));
			s.anonymous = true;
			s.addremove = false;
			s.filter = function(section_id) {
				return uci.get('system', section_id, 'interface') == 'wps';
			};

			o = s.option(form.ListValue, 'trigger', _('Behaviour'));
			o.value('auto', _('Leave alone'));
			o.value('on', _('On'));
			o.value('off', _('Off'));
			o.value('timer', _('Blink'));
			o.default = 'auto';

			o = s.option(form.Value, 'delayon', _('On time'), _('milliseconds'));
			o.datatype = 'uinteger';
			o.placeholder = '500';
			o.depends('trigger', 'timer');

			o = s.option(form.Value, 'delayoff', _('Off time'), _('milliseconds'));
			o.datatype = 'uinteger';
			o.placeholder = '500';
			o.depends('trigger', 'timer');
		}

		/* ---- switch port LEDs ---- */

		s = m.section(form.TableSection, 'led', _('Port LEDs'),
			_('These are owned by the switch chip, which normally blinks them for link and activity. Forcing one On or Off REPLACES that indication, and there is no way back short of a reboot — the driver exposes no "resume normal" setting. Leave them on "Leave alone" unless you specifically want a port LED pinned.'));
		s.anonymous = true;
		s.addremove = false;
		s.filter = function(section_id) {
			var i = uci.get('system', section_id, 'interface');
			return (i == 'lan1' || i == 'lan2' || i == 'wan');
		};

		o = s.option(form.DummyValue, 'name', _('Port'));

		o = s.option(form.ListValue, 'trigger', _('Behaviour'));
		o.value('auto', _('Leave alone (link/activity)'));
		o.value('on', _('Force on'));
		o.value('off', _('Force off'));
		o.default = 'auto';

		/* ---- button ---- */

		s = m.section(form.TableSection, 'button', _('Button'),
			_('This device has one physical button; WPS and Reset are the same button. Each row is a hold-time window: press and release the button, and the first row whose window contains the time you held it decides what happens. The default is a short press doing nothing and a long press rebooting.'));
		s.anonymous = true;
		s.addremove = true;
		s.addbtntitle = _('Add hold-time action');

		o = s.option(form.ListValue, 'button', _('Button'));
		o.value('reset', _('Reset / WPS'));
		o.default = 'reset';

		o = s.option(form.Value, 'min', _('Held at least'), _('seconds'));
		o.datatype = 'uinteger';
		o.default = '0';

		o = s.option(form.Value, 'max', _('Held at most'), _('seconds'));
		o.datatype = 'uinteger';
		o.default = '30';

		o = s.option(form.ListValue, 'action', _('Action'));
		o.value('none', _('Nothing'));
		o.value('reboot', _('Reboot'));
		o.value('factory_reset', _('Factory reset — erases every setting'));
		o.default = 'none';

		return m.render();
	}
});
