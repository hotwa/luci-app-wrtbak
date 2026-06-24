'use strict';
'require view';
'require fs';
'require ui';
'require rpc';

function parseJsonOutput(res) {
	var text = (res && res.stdout) ? res.stdout.trim() : '';

	if (res && res.code)
		throw new Error((res.stderr || text || _('Command failed')).trim());

	if (!text)
		throw new Error(_('Command returned no data'));

	return JSON.parse(text);
}

function itemChecked(item) {
	if (item.category === 'core' || item.category === 'access')
		return item.installed !== false;

	return item.selected === true && item.installed === true;
}

function itemBadges(item) {
	var badges = [];

	if (item.sensitive)
		badges.push(E('span', { 'class': 'cbi-tag cbi-tag-warning' }, _('Sensitive')));

	if (!item.known)
		badges.push(E('span', { 'class': 'cbi-tag' }, _('Unknown')));

	if (!item.installed)
		badges.push(E('span', { 'class': 'cbi-tag' }, _('Not detected')));

	return badges;
}

function downloadFile(path, filename) {
	var form = E('form', {
		method: 'post',
		action: L.env.cgi_base + '/cgi-download',
		enctype: 'application/x-www-form-urlencoded',
		style: 'display:none'
	}, [
		E('input', { type: 'hidden', name: 'sessionid', value: rpc.getSessionID() }),
		E('input', { type: 'hidden', name: 'path', value: path }),
		E('input', { type: 'hidden', name: 'filename', value: filename })
	]);

	document.body.appendChild(form);
	form.submit();
	form.remove();
}

function selectedItems(container) {
	return Array.prototype.slice.call(container.querySelectorAll('input[data-wrtbak-item]:checked'))
		.map(function(input) {
			return input.value;
		});
}

return view.extend({
	load: function() {
		return fs.exec('/usr/bin/wrtbak', [ 'detect', '--json' ]).then(parseJsonOutput);
	},

	render: function(data) {
		var items = Array.isArray(data.items) ? data.items : [];
		var profile = E('input', {
			'class': 'cbi-input-text',
			type: 'text',
			value: L.env.hostname || 'openwrt',
			maxlength: 64,
			pattern: '[A-Za-z0-9._-]+'
		});
		var format = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { value: 'wrtbak' }, '.wrtbak'),
			E('option', { value: 'sysupgrade' }, '.sysupgrade.tar.gz')
		]);
		var table = E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th center', style: 'width:3em' }, ''),
				E('th', { 'class': 'th' }, _('Item')),
				E('th', { 'class': 'th' }, _('Paths')),
				E('th', { 'class': 'th' }, _('Restart'))
			])
		]);

		items.forEach(function(item) {
			var paths = Array.isArray(item.paths) ? item.paths : [];
			var services = Array.isArray(item.restart_services) ? item.restart_services : [];
			var checkbox = E('input', {
				type: 'checkbox',
				value: item.id,
				'data-wrtbak-item': item.id
			});

			checkbox.checked = itemChecked(item);
			checkbox.disabled = paths.length === 0;

			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td center' }, checkbox),
				E('td', { 'class': 'td' }, [
					E('strong', {}, item.label || item.id),
					E('div', { 'class': 'cbi-value-description' }, item.description || ''),
					E('div', {}, itemBadges(item))
				]),
				E('td', { 'class': 'td' }, paths.length ? paths.map(function(path) {
					return E('div', {}, E('code', {}, path));
				}) : E('em', {}, _('No known paths'))),
				E('td', { 'class': 'td' }, services.length ? services.join(', ') : '-')
			]));
		});

		var createButton = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			click: ui.createHandlerFn(this, function(ev) {
				var root = ev.currentTarget.closest('.cbi-section');
				var ids = selectedItems(root);
				var name = profile.value.trim();

				if (!name.match(/^[A-Za-z0-9._-]{1,64}$/)) {
					ui.addNotification(null, E('p', {}, _('Profile name is invalid.')), 'warning');
					return;
				}

				if (!ids.length) {
					ui.addNotification(null, E('p', {}, _('Select at least one item.')), 'warning');
					return;
				}

				return fs.exec('/usr/bin/wrtbak', [ 'create-download',
					'--profile', name,
					'--items', ids.join(','),
					'--format', format.value
				]).then(parseJsonOutput).then(function(result) {
					ui.addNotification(null, E('p', {}, _('Backup archive created.')), 'info');
					downloadFile(result.path, result.filename);
				}).catch(function(err) {
					ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
				});
			})
		}, _('Create and download'));

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Wrtbak')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Profile')),
					E('div', { 'class': 'cbi-value-field' }, profile)
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, _('Archive')),
					E('div', { 'class': 'cbi-value-field' }, format)
				]),
				table,
				E('div', { 'class': 'cbi-page-actions' }, [
					E('button', {
						'class': 'btn cbi-button',
						click: function() { window.location.reload(); }
					}, _('Refresh')),
					' ',
					createButton
				])
			])
		]);
	}
});
