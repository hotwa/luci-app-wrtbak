'use strict';
'require view';
'require fs';
'require ui';
'require rpc';
'require uci';

function parseJsonOutput(res) {
	var text = (res && res.stdout) ? res.stdout.trim() : '';

	if (res && res.code)
		throw new Error((res.stderr || text || _('Command failed')).trim());

	if (!text)
		throw new Error(_('Command returned no data'));

	return JSON.parse(text);
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

function renderBackupRows(table, backups, onDelete) {
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
		table.appendChild(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, E('code', {}, backup.filename || backup.path)),
			E('td', { 'class': 'td' }, backup.format || '-'),
			E('td', { 'class': 'td' }, backup.size == null ? '-' : String(backup.size)),
			E('td', { 'class': 'td' }, backup.modified || '-'),
			E('td', { 'class': 'td right' }, E('button', {
				type: 'button',
				'class': 'btn cbi-button cbi-button-negative',
				click: function() { onDelete(backup); }
			}, _('Delete')))
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

		function listRemoteBackups() {
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
				});
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
				remoteTable
			])
		]);

		updatePagination(rows, pagination, pageSize, pageSummary, previousButton, nextButton);
		renderBackupRows(remoteTable, [], function() {});

		return page;
	}
});
