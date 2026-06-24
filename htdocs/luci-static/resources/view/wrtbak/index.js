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

function pageSizeValue(select, total) {
	if (select.value === 'all')
		return total || 1;

	return Math.max(1, parseInt(select.value, 10) || 10);
}

function updatePagination(rows, state, sizeSelect, summary, prevButton, nextButton) {
	var total = rows.length;
	var size = pageSizeValue(sizeSelect, total);
	var pages = Math.max(1, Math.ceil(total / size));

	if (state.page >= pages)
		state.page = pages - 1;

	if (state.page < 0)
		state.page = 0;

	rows.forEach(function(row, index) {
		var first = state.page * size;
		var last = first + size;
		row.style.display = (index >= first && index < last) ? '' : 'none';
	});

	summary.textContent = String.format('%d / %d', Math.min(state.page + 1, pages), pages);
	prevButton.disabled = state.page <= 0;
	nextButton.disabled = state.page >= pages - 1;
}

function showDownloadResult(container, result) {
	container.style.display = '';
	container.innerHTML = '';
	container.appendChild(E('p', {}, [
		_('Backup archive created: '),
		E('strong', {}, result.filename || result.path)
	]));
	container.appendChild(E('button', {
		type: 'button',
		'class': 'btn cbi-button cbi-button-positive',
		click: function() {
			downloadFile(result.path, result.filename);
		}
	}, _('Download')));
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return fs.exec('/usr/bin/wrtbak', [ 'detect', '--json' ]).then(parseJsonOutput);
	},

	render: function(data) {
		var items = Array.isArray(data.items) ? data.items : [];
		var profile = E('input', {
			id: 'wrtbak-profile',
			name: 'wrtbak_profile',
			'class': 'cbi-input-text',
			type: 'text',
			value: L.env.hostname || 'openwrt',
			maxlength: 64,
			pattern: '[A-Za-z0-9._\\-]+'
		});
		var format = E('select', {
			id: 'wrtbak-format',
			name: 'wrtbak_format',
			'class': 'cbi-input-select'
		}, [
			E('option', { value: 'wrtbak' }, '.wrtbak'),
			E('option', { value: 'sysupgrade' }, '.sysupgrade.tar.gz')
		]);
		var pageSize = E('select', {
			id: 'wrtbak-page-size',
			name: 'wrtbak_page_size',
			'class': 'cbi-input-select'
		}, [
			E('option', { value: '10' }, '10'),
			E('option', { value: '20' }, '20'),
			E('option', { value: '50' }, '50'),
			E('option', { value: 'all' }, _('All'))
		]);
		var pageSummary = E('span', { 'class': 'wrtbak-page-summary' }, '');
		var previousButton = E('button', {
			type: 'button',
			'class': 'btn cbi-button',
			click: function() {
				pagination.page--;
				updatePagination(rows, pagination, pageSize, pageSummary, previousButton, nextButton);
			}
		}, _('Previous'));
		var nextButton = E('button', {
			type: 'button',
			'class': 'btn cbi-button',
			click: function() {
				pagination.page++;
				updatePagination(rows, pagination, pageSize, pageSummary, previousButton, nextButton);
			}
		}, _('Next'));
		var rows = [];
		var pagination = { page: 0 };
		var resultPanel = E('div', {
			'class': 'alert-message info',
			style: 'display:none'
		});
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

			var row = E('tr', { 'class': 'tr' }, [
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
			]);

			rows.push(row);
			table.appendChild(row);
		});

		pageSize.addEventListener('change', function() {
			pagination.page = 0;
			updatePagination(rows, pagination, pageSize, pageSummary, previousButton, nextButton);
		});

		var createButton = E('button', {
			type: 'button',
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
					showDownloadResult(resultPanel, result);
					ui.addNotification(null, E('p', {}, _('Backup archive created.')), 'info');
					downloadFile(result.path, result.filename);
				}).catch(function(err) {
					ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
				});
			})
		}, _('Create and download'));

		var page = E('div', { 'class': 'wrtbak-page' }, [
			E('h2', {}, _('Wrtbak')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for': 'wrtbak-profile' }, _('Profile')),
					E('div', { 'class': 'cbi-value-field' }, profile)
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for': 'wrtbak-format' }, _('Archive')),
					E('div', { 'class': 'cbi-value-field' }, format)
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for': 'wrtbak-page-size' }, _('Rows per page')),
					E('div', { 'class': 'cbi-value-field' }, [
						pageSize,
						' ',
						previousButton,
						' ',
						pageSummary,
						' ',
						nextButton
					])
				]),
				table,
				resultPanel,
				E('div', { 'class': 'cbi-page-actions' }, [
					E('button', {
						type: 'button',
						'class': 'btn cbi-button',
						click: function() { window.location.reload(); }
					}, _('Refresh')),
					' ',
					createButton
				])
			])
		]);

		updatePagination(rows, pagination, pageSize, pageSummary, previousButton, nextButton);

		return page;
	}
});
