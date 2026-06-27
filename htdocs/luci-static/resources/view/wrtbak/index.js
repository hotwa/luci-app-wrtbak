'use strict';
'require view';
'require fs';
'require ui';
'require rpc';
'require uci';

function parseJsonOutput(res) {
	var text = (res && res.stdout) ? res.stdout.trim() : '';
	var data = null;

	if (text) {
		try {
			data = JSON.parse(text);
		} catch (err) {
			if (res && res.code)
				throw new Error((res.stderr || text || _('Command failed')).trim());

			throw err;
		}
	}

	if (res && res.code) {
		var error = new Error((data && data.message) || (res.stderr || text || _('Command failed')).trim());
		error.data = data;
		throw error;
	}

	if (!data)
		throw new Error(_('Command returned no data'));

	return data;
}

function runWrtbak(args) {
	return fs.exec('/usr/bin/wrtbak', args).then(parseJsonOutput);
}

function cfg(section, option, fallback) {
	var value = uci.get('wrtbak', section, option);
	return value == null ? fallback : value;
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
	var targetName = 'wrtbak-download-frame';
	var frame = document.querySelector('iframe[name="' + targetName + '"]');

	if (!frame) {
		frame = E('iframe', {
			name: targetName,
			style: 'display:none'
		});
		document.body.appendChild(frame);
	}

	var form = E('form', {
		method: 'post',
		action: L.env.cgi_base + '/cgi-download',
		enctype: 'application/x-www-form-urlencoded',
		target: targetName,
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

function field(id, label, node) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title', 'for': id }, label),
		E('div', { 'class': 'cbi-value-field' }, node)
	]);
}

function textInput(id, value, password) {
	return E('input', {
		id: id,
		'class': 'cbi-input-text',
		type: password ? 'password' : 'text',
		value: value || ''
	});
}

function numberInput(id, value, min, max) {
	return E('input', {
		id: id,
		'class': 'cbi-input-text',
		type: 'number',
		min: min,
		max: max,
		value: value || '0'
	});
}

function checkboxInput(id, checked) {
	var input = E('input', {
		id: id,
		type: 'checkbox'
	});
	input.checked = checked === true || checked === '1';
	return input;
}

function selectInput(id, value, options) {
	var select = E('select', {
		id: id,
		'class': 'cbi-input-select'
	}, options.map(function(option) {
		return E('option', { value: option[0] }, option[1]);
	}));
	select.value = value;
	return select;
}

function remoteTargetDriver(target) {
	return target === 'webdav' ? 'curl' : 'rclone';
}

function renderBackupRows(table, backups, onDelete, onRestore) {
	table.innerHTML = '';
	table.appendChild(E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, _('File')),
		E('th', { 'class': 'th' }, _('Format')),
		E('th', { 'class': 'th' }, _('Size')),
		E('th', { 'class': 'th' }, _('Modified')),
		E('th', { 'class': 'th right' }, _('Action'))
	]));

	if (!backups.length) {
		table.appendChild(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', colspan: 5 }, E('em', {}, _('No remote backups')))
		]));
		return;
	}

	backups.forEach(function(backup) {
		var actions;

		if (backup.legacy === true) {
			actions = [
				E('span', { 'class': 'cbi-tag wrtbak-legacy-backup' }, _('Legacy')),
				' ',
				E('em', {}, _('Restore and delete disabled'))
			];
		} else {
			actions = [
				E('button', {
					type: 'button',
					'class': 'btn cbi-button cbi-button-action',
					click: function() { onRestore(backup); }
				}, backup.format === 'sysupgrade' ? _('Restore via sysupgrade') : _('Restore')),
				' ',
				E('button', {
					type: 'button',
					'class': 'btn cbi-button cbi-button-negative',
					click: function() { onDelete(backup); }
				}, _('Delete'))
			];
		}

		table.appendChild(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, E('code', {}, backup.filename || backup.path)),
			E('td', { 'class': 'td' }, backup.format || '-'),
			E('td', { 'class': 'td' }, backup.size == null ? '-' : String(backup.size)),
			E('td', { 'class': 'td' }, backup.modified || '-'),
			E('td', { 'class': 'td right' }, actions)
		]));
	});
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return Promise.all([
			runWrtbak([ 'detect', '--json' ]),
			runWrtbak([ 'remote-status', '--json' ]),
			uci.load('wrtbak')
		]).then(function(results) {
			return {
				detect: results[0],
				remote: results[1]
			};
		});
	},

	render: function(data) {
		var items = Array.isArray(data.detect.items) ? data.detect.items : [];
		var remoteStatus = data.remote || {};
		var schedule = remoteStatus.schedule || {};
		var profile = E('input', {
			id: 'wrtbak-profile',
			name: 'wrtbak_profile',
			'class': 'cbi-input-text',
			type: 'text',
			value: cfg('auto', 'profile', L.env.hostname || 'openwrt'),
			maxlength: 64,
			pattern: '[A-Za-z0-9._\\-]+'
		});
		var format = selectInput('wrtbak-format', cfg('auto', 'format', 'wrtbak'), [
			[ 'wrtbak', '.wrtbak' ],
			[ 'sysupgrade', '.sysupgrade.tar.gz' ]
		]);
		var defaultTarget = selectInput('wrtbak-default-target', cfg('main', 'default_target', remoteStatus.default_target || 'webdav'), [
			[ 'webdav', 'WebDAV' ],
			[ 's3', 'S3' ]
		]);
		var deviceId = textInput('wrtbak-device-id', cfg('main', 'device_id', remoteStatus.device_id || ''));
		var pruneMax = numberInput('wrtbak-prune-max', cfg('auto', 'max_backups', '0'), 0, 999);
		var webdavEnabled = checkboxInput('wrtbak-webdav-enabled', cfg('webdav', 'enabled', '0'));
		var webdavUrl = textInput('wrtbak-webdav-url', cfg('webdav', 'url', ''));
		var webdavUsername = textInput('wrtbak-webdav-username', cfg('webdav', 'username', ''));
		var webdavPassword = textInput('wrtbak-webdav-password', '', true);
		var webdavPath = textInput('wrtbak-webdav-path', cfg('webdav', 'path', '/'));
		var s3Enabled = checkboxInput('wrtbak-s3-enabled', cfg('s3', 'enabled', '0'));
		var s3Endpoint = textInput('wrtbak-s3-endpoint', cfg('s3', 'endpoint', ''));
		var s3Region = textInput('wrtbak-s3-region', cfg('s3', 'region', 'us-east-1'));
		var s3Bucket = textInput('wrtbak-s3-bucket', cfg('s3', 'bucket', ''));
		var s3AccessKey = textInput('wrtbak-s3-access-key', cfg('s3', 'access_key', ''));
		var s3SecretKey = textInput('wrtbak-s3-secret-key', '', true);
		var s3Path = textInput('wrtbak-s3-path', cfg('s3', 'path', '/'));
		var s3ForcePathStyle = checkboxInput('wrtbak-s3-force-path-style', cfg('s3', 'force_path_style', '1'));
		var scheduleEnabled = checkboxInput('wrtbak-schedule-enabled', cfg('auto', 'enabled', schedule.enabled ? '1' : '0'));
		var scheduleFrequency = selectInput('wrtbak-schedule-frequency', cfg('auto', 'frequency', 'daily'), [
			[ 'daily', _('Daily') ],
			[ 'weekly', _('Weekly') ],
			[ 'monthly', _('Monthly') ]
		]);
		var scheduleTime = textInput('wrtbak-schedule-time', cfg('auto', 'time', '03:30'));
		var scheduleWeekday = numberInput('wrtbak-schedule-weekday', cfg('auto', 'weekday', '0'), 0, 6);
		var scheduleDay = numberInput('wrtbak-schedule-day', cfg('auto', 'day_of_month', '1'), 1, 31);
		var scheduleItems = selectInput('wrtbak-schedule-items', cfg('auto', 'items', 'all'), [
			[ 'all', _('All default items') ],
			[ 'current', _('Current selection') ]
		]);
		var pageSize = selectInput('wrtbak-page-size', '10', [
			[ '10', '10' ],
			[ '20', '20' ],
			[ '50', '50' ],
			[ 'all', _('All') ]
		]);
		var pageSummary = E('span', { 'class': 'wrtbak-page-summary' }, '');
		var rows = [];
		var pagination = { page: 0 };
		var resultPanel = E('div', { 'class': 'alert-message info', style: 'display:none' });
		var remotePanel = E('div', { 'class': 'alert-message info', style: 'display:none' });
		var remoteTable = E('table', { 'class': 'table wrtbak-remote-table' });
		var restoreState = { phase: 'idle', target: null, backup: null, download: null, prepare: null, prebackup: null, apply: null, sysupgradePreflight: null, error: null, unknown: false };
		var restorePanel = E('div', { 'class': 'cbi-section wrtbak-restore-panel' });
		var confirmationInput = textInput('wrtbak-restore-confirmation', '');
		var prebackupButton;
		var applyButton;
		var applyAllButton;
		var sysupgradePreflightButton;
		var sysupgradeExecuteButton;
		var previousButton;
		var nextButton;
		var table = E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th center', style: 'width:3em' }, ''),
				E('th', { 'class': 'th' }, _('Item')),
				E('th', { 'class': 'th' }, _('Paths')),
				E('th', { 'class': 'th' }, _('Restart'))
			])
		]);

		previousButton = E('button', {
			type: 'button',
			'class': 'btn cbi-button',
			click: function() {
				pagination.page--;
				updatePagination(rows, pagination, pageSize, pageSummary, previousButton, nextButton);
			}
		}, _('Previous'));
		nextButton = E('button', {
			type: 'button',
			'class': 'btn cbi-button',
			click: function() {
				pagination.page++;
				updatePagination(rows, pagination, pageSize, pageSummary, previousButton, nextButton);
			}
		}, _('Next'));

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

		function saveConfig() {
			uci.set('wrtbak', 'main', 'default_target', defaultTarget.value);
			uci.set('wrtbak', 'main', 'device_id', deviceId.value.trim());
			uci.set('wrtbak', 'webdav', 'enabled', webdavEnabled.checked ? '1' : '0');
			uci.set('wrtbak', 'webdav', 'driver', 'curl');
			uci.set('wrtbak', 'webdav', 'url', webdavUrl.value.trim());
			uci.set('wrtbak', 'webdav', 'username', webdavUsername.value.trim());
			if (webdavPassword.value)
				uci.set('wrtbak', 'webdav', 'password', webdavPassword.value);
			uci.set('wrtbak', 'webdav', 'path', webdavPath.value.trim() || '/');
			uci.set('wrtbak', 's3', 'enabled', s3Enabled.checked ? '1' : '0');
			uci.set('wrtbak', 's3', 'driver', 'rclone');
			uci.set('wrtbak', 's3', 'endpoint', s3Endpoint.value.trim());
			uci.set('wrtbak', 's3', 'region', s3Region.value.trim() || 'us-east-1');
			uci.set('wrtbak', 's3', 'bucket', s3Bucket.value.trim());
			uci.set('wrtbak', 's3', 'access_key', s3AccessKey.value.trim());
			if (s3SecretKey.value)
				uci.set('wrtbak', 's3', 'secret_key', s3SecretKey.value);
			uci.set('wrtbak', 's3', 'path', s3Path.value.trim() || '/');
			uci.set('wrtbak', 's3', 'force_path_style', s3ForcePathStyle.checked ? '1' : '0');
			uci.set('wrtbak', 'auto', 'enabled', scheduleEnabled.checked ? '1' : '0');
			uci.set('wrtbak', 'auto', 'frequency', scheduleFrequency.value);
			uci.set('wrtbak', 'auto', 'time', scheduleTime.value.trim());
			uci.set('wrtbak', 'auto', 'weekday', scheduleWeekday.value);
			uci.set('wrtbak', 'auto', 'day_of_month', scheduleDay.value);
			uci.set('wrtbak', 'auto', 'profile', profile.value.trim());
			uci.set('wrtbak', 'auto', 'items', scheduleItems.value);
			uci.set('wrtbak', 'auto', 'format', format.value);
			uci.set('wrtbak', 'auto', 'max_backups', pruneMax.value || '0');
			uci.set('wrtbak', 'auto', 'target', 'default');
			return uci.save('wrtbak');
		}

		function selectedTarget() {
			return defaultTarget.value || 'default';
		}

		function restoreInputPath() {
			return restoreState.download && restoreState.download.local_path;
		}

		function isSysupgradeRestore() {
			return restoreState.prepare && restoreState.prepare.format === 'sysupgrade';
		}

		function canRunConfirmedRestore() {
			return restoreState.phase === 'prebackup_ready' && confirmationInput.value === 'RESTORE' && restoreState.prebackup && restoreState.prebackup.path;
		}

		function updateRestoreButtons() {
			if (!prebackupButton || !applyButton)
				return;

			prebackupButton.disabled = restoreState.phase !== 'prepared';
			applyButton.disabled = restoreState.phase !== 'prebackup_ready' || confirmationInput.value !== 'RESTORE' || isSysupgradeRestore();
			applyAllButton.disabled = restoreState.phase !== 'prebackup_ready' || confirmationInput.value !== 'RESTORE' || isSysupgradeRestore();
			sysupgradePreflightButton.disabled = restoreState.phase !== 'prebackup_ready' || confirmationInput.value !== 'RESTORE' || !isSysupgradeRestore();
			sysupgradeExecuteButton.disabled = restoreState.phase !== 'prebackup_ready' || confirmationInput.value !== 'RESTORE' || !restoreState.sysupgradePreflight || !isSysupgradeRestore();
		}

		function resetRestoreState() {
			restoreState.phase = 'idle';
			restoreState.target = null;
			restoreState.backup = null;
			restoreState.download = null;
			restoreState.prepare = null;
			restoreState.prebackup = null;
			restoreState.apply = null;
			restoreState.sysupgradePreflight = null;
			restoreState.error = null;
			restoreState.unknown = false;
			confirmationInput.value = '';
			renderRestorePanel();
		}

		function setRestorePhase(phase) {
			restoreState.phase = phase;
			renderRestorePanel();
		}

		function appendJsonList(parent, title, values) {
			var list = Array.isArray(values) ? values : [];
			parent.appendChild(E('p', {}, [
				E('strong', {}, title),
				': ',
				list.length ? list.join(', ') : '-'
			]));
		}

		function appendRestorePlan(parent, prepare) {
			var plan = prepare && prepare.plan ? prepare.plan : {};
			var paths = Array.isArray(plan.paths) ? plan.paths : [];

			parent.appendChild(E('p', {}, [
				E('strong', {}, _('Archive')),
				': ',
				(prepare && prepare.format) || '-',
				' ',
				(prepare && prepare.archive && prepare.archive.filename) || ''
			]));
			parent.appendChild(E('p', {}, [
				E('strong', {}, _('Source')),
				': ',
				(prepare && prepare.source_device && prepare.source_device.hostname) || '-',
				' / ',
				(prepare && prepare.source_device && prepare.source_device.board) || '-'
			]));
			parent.appendChild(E('p', {}, [
				E('strong', {}, _('Files')),
				': ',
				String(plan.file_count || 0),
				' / ',
				String(plan.total_bytes || 0),
				' bytes'
			]));
			appendJsonList(parent, _('Restart services'), plan.restart_services);

			if (prepare && prepare.compatibility && Array.isArray(prepare.compatibility.warnings) && prepare.compatibility.warnings.length) {
				parent.appendChild(E('ul', { 'class': 'wrtbak-restore-warnings' }, prepare.compatibility.warnings.map(function(warning) {
					return E('li', {}, warning.message || warning.code || String(warning));
				})));
			}

			if (paths.length) {
				parent.appendChild(E('table', { 'class': 'table wrtbak-restore-paths' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, _('Path')),
						E('th', { 'class': 'th' }, _('Type')),
						E('th', { 'class': 'th' }, _('Action'))
					])
				]));
				var pathTable = parent.lastChild;
				paths.slice(0, 20).forEach(function(path) {
					pathTable.appendChild(E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td' }, E('code', {}, path.path || '-')),
						E('td', { 'class': 'td' }, path.type || '-'),
						E('td', { 'class': 'td' }, path.action || '-')
					]));
				});
			}
		}

		function appendApplyResult(parent, result) {
			if (!result)
				return;

			if (result.code === 'sysupgrade_failed') {
				parent.appendChild(E('div', { 'class': 'alert-message warning' }, String.format('%s: %s', _('Sysupgrade failed'), result.sysupgrade_exit_code)));
				return;
			}

			if (result.operation === 'restore-sysupgrade') {
				parent.appendChild(E('p', {}, [
					E('strong', {}, _('Sysupgrade')),
					': ',
					result.status || '-',
					' / ',
					_('exit'),
					' ',
					String(result.sysupgrade_exit_code == null ? '-' : result.sysupgrade_exit_code)
				]));
				return;
			}

			parent.appendChild(E('p', {}, [
				E('strong', {}, _('Written')),
				': ',
				String(result.written_count || 0),
				' / ',
				_('skipped'),
				' ',
				String(result.skipped_count || 0)
			]));
			appendJsonList(parent, 'blocked_restart_services', result.blocked_restart_services);
			appendJsonList(parent, _('Restarted services'), result.restarted_services);
			appendJsonList(parent, _('Missing from archive'), result.missing_from_archive);
			if (result.restore_log)
				parent.appendChild(E('p', {}, [ E('strong', {}, _('Restore log')), ': ', E('code', {}, result.restore_log) ]));
		}

		function renderRestorePanel() {
			restorePanel.innerHTML = '';
			restorePanel.appendChild(E('h3', {}, _('Restore review')));

			if (restoreState.phase === 'idle') {
				restorePanel.appendChild(E('p', {}, _('No restore selected.')));
				updateRestoreButtons();
				return;
			}

			restorePanel.appendChild(E('p', {}, [
				E('strong', {}, _('Status')),
				': ',
				restoreState.phase
			]));

			if (restoreState.backup) {
				restorePanel.appendChild(E('p', {}, [
					E('strong', {}, _('Remote path')),
					': ',
					E('code', {}, restoreState.backup.path || restoreState.backup.filename || '-')
				]));
			}

			if (restoreState.download) {
				restorePanel.appendChild(E('p', {}, [
					E('strong', {}, _('Local path')),
					': ',
					E('code', {}, restoreState.download.local_path || '-')
				]));
			}

			if (restoreState.prepare)
				appendRestorePlan(restorePanel, restoreState.prepare);

			if (restoreState.prebackup) {
				restorePanel.appendChild(E('p', {}, [
					E('strong', {}, _('Pre-restore backup')),
					': ',
					E('code', {}, restoreState.prebackup.path || '-')
				]));
			}

			if (restoreState.apply)
				appendApplyResult(restorePanel, restoreState.apply);

			if (restoreState.error)
				restorePanel.appendChild(E('div', { 'class': 'alert-message danger' }, restoreState.error));

			if (restoreState.unknown)
				restorePanel.appendChild(E('div', { 'class': 'alert-message warning wrtbak-restore-unknown' }, _('Restore handoff status is unknown. Reconnect and inspect router state.')));

			restorePanel.appendChild(field('wrtbak-restore-confirmation', _('Confirmation'), confirmationInput));
			restorePanel.appendChild(E('div', { 'class': 'cbi-page-actions' }, [
				prebackupButton,
				' ',
				applyButton,
				' ',
				applyAllButton,
				' ',
				sysupgradePreflightButton,
				' ',
				sysupgradeExecuteButton
			]));
			updateRestoreButtons();
		}

		function backupArgs(root) {
			var ids = selectedItems(root);
			var name = profile.value.trim();

			if (!name.match(/^[A-Za-z0-9._-]{1,64}$/))
				throw new Error(_('Profile name is invalid.'));

			if (!ids.length)
				throw new Error(_('Select at least one item.'));

			return {
				profile: name,
				items: ids.join(','),
				format: format.value
			};
		}

		function failRestore(err, unknown) {
			restoreState.apply = err && err.data ? err.data : restoreState.apply;
			restoreState.error = err && err.data ? (err.data.message || err.data.code) : ((err && err.message) || String(err));
			restoreState.unknown = unknown === true;
			setRestorePhase('failed');
			ui.addNotification(null, E('p', {}, restoreState.error), 'danger');
		}

		function restoreBackup(backup) {
			restoreState.phase = 'downloading';
			restoreState.target = selectedTarget();
			restoreState.backup = backup;
			restoreState.download = null;
			restoreState.prepare = null;
			restoreState.prebackup = null;
			restoreState.apply = null;
			restoreState.sysupgradePreflight = null;
			restoreState.error = null;
			restoreState.unknown = false;
			confirmationInput.value = '';
			renderRestorePanel();

			return runWrtbak([ 'remote-download', '--target', selectedTarget(), '--path', backup.path, '--json' ]).then(function(download) {
				restoreState.download = download;
				return runWrtbak([ 'restore-prepare', '--input', download.local_path, '--json' ]);
			}).then(function(prepare) {
				restoreState.prepare = prepare;
				setRestorePhase('prepared');
				ui.addNotification(null, E('p', {}, _('Restore archive prepared.')), 'info');
			}).catch(function(err) {
				failRestore(err);
			});
		}

		function createPrebackup() {
			if (restoreState.phase !== 'prepared')
				return Promise.resolve();

			return runWrtbak([ 'restore-prebackup', '--profile', 'pre-restore', '--items', 'all', '--format', 'wrtbak', '--json' ]).then(function(prebackup) {
				restoreState.prebackup = prebackup;
				setRestorePhase('prebackup_ready');
				ui.addNotification(null, E('p', {}, _('Pre-restore backup created.')), 'info');
			}).catch(function(err) {
				failRestore(err);
			});
		}

		function applyWrtbak(mode, itemsValue) {
			if (!canRunConfirmedRestore())
				return Promise.resolve();

			setRestorePhase('applying');
			return runWrtbak([ 'restore-apply', '--input', restoreInputPath(), '--mode', mode, '--items', itemsValue, '--prebackup', restoreState.prebackup.path, '--confirm', 'RESTORE', '--restart-services', '0', '--json' ]).then(function(result) {
				restoreState.apply = result;
				setRestorePhase('applied');
				ui.addNotification(null, E('p', {}, _('Restore completed.')), 'info');
			}).catch(function(err) {
				failRestore(err);
			});
		}

		function preflightSysupgrade() {
			if (!canRunConfirmedRestore())
				return Promise.resolve();

			return runWrtbak([ 'restore-sysupgrade', '--input', restoreInputPath(), '--prebackup', restoreState.prebackup.path, '--confirm', 'RESTORE', '--execute', '0', '--json' ]).then(function(result) {
				restoreState.sysupgradePreflight = result;
				restoreState.apply = result;
				setRestorePhase('prebackup_ready');
				ui.addNotification(null, E('p', {}, _('Sysupgrade preflight completed.')), 'info');
			}).catch(function(err) {
				failRestore(err);
			});
		}

		function executeSysupgrade() {
			if (!canRunConfirmedRestore() || !restoreState.sysupgradePreflight)
				return Promise.resolve();

			setRestorePhase('applying');
			return runWrtbak([ 'restore-sysupgrade', '--input', restoreInputPath(), '--prebackup', restoreState.prebackup.path, '--confirm', 'RESTORE', '--execute', '1', '--json' ]).then(function(result) {
				restoreState.apply = result;
				setRestorePhase('applied');
				ui.addNotification(null, E('p', {}, _('Sysupgrade restore handed off.')), 'info');
			}).catch(function(err) {
				if (!err.data) {
					failRestore(err, true);
					return;
				}
				if (err.data.code === 'sysupgrade_failed')
					restoreState.apply = err.data;
				failRestore(err);
			});
		}

		function listRemoteBackups() {
			resetRestoreState();
			return runWrtbak([ 'remote-list', '--target', selectedTarget(), '--json' ]).then(function(result) {
				remotePanel.style.display = '';
				remotePanel.textContent = String.format('%s: %s', _('Remote target'), remoteTargetDriver(result.target));
				renderBackupRows(remoteTable, Array.isArray(result.backups) ? result.backups : [], function(backup) {
					runWrtbak([ 'remote-delete', '--target', selectedTarget(), '--path', backup.path, '--json' ]).then(function() {
						ui.addNotification(null, E('p', {}, _('Remote backup deleted.')), 'info');
						return listRemoteBackups();
					}).catch(function(err) {
						ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
					});
				}, restoreBackup);
			});
		}

		var createButton = E('button', {
			type: 'button',
			'class': 'btn cbi-button cbi-button-action',
			click: ui.createHandlerFn(this, function(ev) {
				var root = ev.currentTarget.closest('.wrtbak-page');
				var args;

				try {
					args = backupArgs(root);
				} catch (err) {
					ui.addNotification(null, E('p', {}, err.message || String(err)), 'warning');
					return;
				}

				return runWrtbak([ 'create-download',
					'--profile', args.profile,
					'--items', args.items,
					'--format', args.format
				]).then(function(result) {
					showDownloadResult(resultPanel, result);
					ui.addNotification(null, E('p', {}, _('Backup archive created.')), 'info');
					downloadFile(result.path, result.filename);
				}).catch(function(err) {
					ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
				});
			})
		}, _('Create and download'));

		var remoteUploadButton = E('button', {
			type: 'button',
			'class': 'btn cbi-button cbi-button-action',
			click: ui.createHandlerFn(this, function(ev) {
				var root = ev.currentTarget.closest('.wrtbak-page');
				var args;

				try {
					args = backupArgs(root);
				} catch (err) {
					ui.addNotification(null, E('p', {}, err.message || String(err)), 'warning');
					return;
				}

				return saveConfig().then(function() {
					return runWrtbak([ 'remote-upload', '--target', selectedTarget(), '--profile', args.profile, '--items', args.items, '--format', args.format, '--prune-max', pruneMax.value || '0', '--json' ]);
				}).then(function(result) {
					remotePanel.style.display = '';
					remotePanel.textContent = String.format('%s: %s', _('Uploaded'), result.remote_path);
					ui.addNotification(null, E('p', {}, _('Remote backup uploaded.')), 'info');
					return listRemoteBackups();
				}).catch(function(err) {
					ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
				});
			})
		}, _('Upload to remote'));

		var saveButton = E('button', {
			type: 'button',
			'class': 'btn cbi-button cbi-button-positive',
			click: ui.createHandlerFn(this, function() {
				return saveConfig().then(function() {
					ui.addNotification(null, E('p', {}, _('Configuration saved.')), 'info');
				}).catch(function(err) {
					ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
				});
			})
		}, _('Save'));

		var testButton = E('button', {
			type: 'button',
			'class': 'btn cbi-button',
			click: ui.createHandlerFn(this, function() {
				return saveConfig().then(function() {
					return runWrtbak([ 'remote-test', '--target', selectedTarget(), '--json' ]);
				}).then(function(result) {
					remotePanel.style.display = '';
					remotePanel.textContent = String.format('%s: %s', _('Remote test'), result.remote_path);
					ui.addNotification(null, E('p', {}, _('Remote target is reachable.')), 'info');
				}).catch(function(err) {
					ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
				});
			})
		}, _('Test remote'));

		var listButton = E('button', {
			type: 'button',
			'class': 'btn cbi-button',
			click: ui.createHandlerFn(this, function() {
				return saveConfig().then(listRemoteBackups).catch(function(err) {
					ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
				});
			})
		}, _('Manage backups'));

		var scheduleButton = E('button', {
			type: 'button',
			'class': 'btn cbi-button',
			click: ui.createHandlerFn(this, function() {
				return saveConfig().then(function() {
					return runWrtbak([ 'schedule-apply', '--json' ]);
				}).then(function(result) {
					remotePanel.style.display = '';
					remotePanel.textContent = String.format('%s: %s', _('Schedule'), result.action);
					ui.addNotification(null, E('p', {}, _('Schedule updated.')), 'info');
				}).catch(function(err) {
					ui.addNotification(null, E('p', {}, err.message || String(err)), 'danger');
				});
			})
		}, _('Apply schedule'));

		confirmationInput.addEventListener('input', updateRestoreButtons);

		prebackupButton = E('button', {
			type: 'button',
			'class': 'btn cbi-button cbi-button-action',
			click: ui.createHandlerFn(this, createPrebackup)
		}, _('Create pre-restore backup'));

		applyButton = E('button', {
			type: 'button',
			'class': 'btn cbi-button cbi-button-positive',
			click: ui.createHandlerFn(this, function() {
				return applyWrtbak('selected', 'core-system');
			})
		}, _('Apply core system'));

		applyAllButton = E('button', {
			type: 'button',
			'class': 'btn cbi-button cbi-button-negative',
			click: ui.createHandlerFn(this, function() {
				return applyWrtbak('all', 'all');
			})
		}, _('Apply all'));

		sysupgradePreflightButton = E('button', {
			type: 'button',
			'class': 'btn cbi-button',
			click: ui.createHandlerFn(this, preflightSysupgrade)
		}, _('Sysupgrade preflight'));

		sysupgradeExecuteButton = E('button', {
			id: 'wrtbak-sysupgrade-execute',
			type: 'button',
			'class': 'btn cbi-button cbi-button-negative wrtbak-sysupgrade-execute',
			click: ui.createHandlerFn(this, executeSysupgrade)
		}, _('Execute sysupgrade restore'));

		var page = E('div', { 'class': 'wrtbak-page' }, [
			E('h2', {}, _('Wrtbak')),
			E('div', { 'class': 'cbi-section' }, [
				field('wrtbak-profile', _('Profile'), profile),
				field('wrtbak-format', _('Archive'), format),
				field('wrtbak-page-size', _('Rows per page'), [ pageSize, ' ', previousButton, ' ', pageSummary, ' ', nextButton ]),
				table,
				resultPanel,
				E('div', { 'class': 'cbi-page-actions' }, [
					E('button', { type: 'button', 'class': 'btn cbi-button', click: function() { window.location.reload(); } }, _('Refresh')),
					' ', createButton,
					' ', remoteUploadButton
				])
			]),
			E('div', { 'class': 'cbi-section wrtbak-remote-config' }, [
				E('h3', {}, _('Remote storage')),
				field('wrtbak-default-target', _('Target'), defaultTarget),
				field('wrtbak-device-id', _('Device ID'), deviceId),
				field('wrtbak-prune-max', _('Maximum backups'), pruneMax),
				E('h4', {}, 'WebDAV'),
				field('wrtbak-webdav-enabled', _('Enabled'), webdavEnabled),
				field('wrtbak-webdav-url', _('URL'), webdavUrl),
				field('wrtbak-webdav-username', _('Username'), webdavUsername),
				field('wrtbak-webdav-password', _('Password'), webdavPassword),
				field('wrtbak-webdav-path', _('Path'), webdavPath),
				E('h4', {}, 'S3'),
				field('wrtbak-s3-enabled', _('Enabled'), s3Enabled),
				field('wrtbak-s3-endpoint', _('Endpoint'), s3Endpoint),
				field('wrtbak-s3-region', _('Region'), s3Region),
				field('wrtbak-s3-bucket', _('Bucket'), s3Bucket),
				field('wrtbak-s3-access-key', _('Access Key ID'), s3AccessKey),
				field('wrtbak-s3-secret-key', _('Secret Access Key'), s3SecretKey),
				field('wrtbak-s3-path', _('Path'), s3Path),
				field('wrtbak-s3-force-path-style', _('Path style'), s3ForcePathStyle),
				E('div', { 'class': 'cbi-page-actions' }, [ saveButton, ' ', testButton, ' ', listButton ])
			]),
			E('div', { 'class': 'cbi-section wrtbak-schedule-config' }, [
				E('h3', {}, _('Automatic backup')),
				field('wrtbak-schedule-enabled', _('Enabled'), scheduleEnabled),
				field('wrtbak-schedule-frequency', _('Frequency'), scheduleFrequency),
				field('wrtbak-schedule-time', _('Time'), scheduleTime),
				field('wrtbak-schedule-weekday', _('Weekday'), scheduleWeekday),
				field('wrtbak-schedule-day', _('Day of month'), scheduleDay),
				field('wrtbak-schedule-items', _('Items'), scheduleItems),
				E('div', { 'class': 'cbi-page-actions' }, [ scheduleButton ])
			]),
			E('div', { 'class': 'cbi-section wrtbak-remote-backups' }, [
				E('h3', {}, _('Remote backups')),
				remotePanel,
				remoteTable,
				restorePanel
			])
		]);

		updatePagination(rows, pagination, pageSize, pageSummary, previousButton, nextButton);
		renderBackupRows(remoteTable, [], function() {}, function() {});
		renderRestorePanel();

		return page;
	}
});
