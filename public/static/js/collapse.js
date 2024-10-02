/*
 * Copyright (C) 2020-2023 Birte Kristina Friesel
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

function setLang(lang) {
	document.cookie = 'lang=' + lang + ';SameSite=None;Secure';
	location.reload();
}

function setTheme(theme) {
	localStorage.setItem('theme', theme);
	if (!otherTheme.hasOwnProperty(theme)) {
		theme = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
	}
	addStyleSheet(theme, 'theme');
}

function reload_app() {
	// TODO use a variable instead of window.location.href, as
	// window.location.href may be /z/...
	// Until then, we guard it by only reloading whin moreinfo is not expanded.
	if ($('.expanded-moreinfo').length == 0) {
		$.get(window.location.href, {ajax: 1}, function(data) {
			// TODO check expanded-moreinfo again here (until the issue itself has been resolved)
			$('div.app > ul').html(data);
			dbf_reg_handlers();
			setTimeout(reload_app, 60000);
		}).fail(function() {
			setTimeout(reload_app, 10000);
		});
	} else {
		setTimeout(reload_app, 30000);
	}
}

function dbf_show_moreinfo(trainElem, keep_old) {
	const routeprev = trainElem.data('routeprev').split('|');
	const routenext = trainElem.data('routenext').split('|');
	const moreinfo = trainElem.data('moreinfo').split('|');
	$('.moreinfo').each(function() {
		const infoElem = $(this);
		if (!keep_old) {
			$('.moreinfo .train-line').removeClass('sbahn fern ext ubahn bus tram').addClass(trainElem.data('linetype'));
			$('.moreinfo .train-line').text(trainElem.data('line'));
			$('.moreinfo .train-no').text(trainElem.data('no'));
			$('.moreinfo .train-origin').text(trainElem.data('from'));
			$('.moreinfo .train-dest').text(trainElem.data('to'));
			$('.moreinfo .minfo').text('');
			$('.moreinfo .mfooter').html('');
			$('.moreinfo .verbose').html('');
			$('.moreinfo .mroute').html('');
			$('.moreinfo ul').html('');
			var dataline = '';
			if (trainElem.data('arrival') != '') {
				dataline += '<div><div class="arrival">An: ' + trainElem.data('arrival') + '</div></div>';
			} else {
				dataline += '<div><div class="arrival"></div></div>';
			}
			if (trainElem.data('platform') != '') {
				dataline += '<div><div class="platform">Gleis ' + trainElem.data('platform') + '</div></div>';
			} else {
				dataline += '<div><div class="platform"></div></div>';
			}
			if (trainElem.data('departure') != '') {
				dataline += '<div><div class="departure">Ab: ' + trainElem.data('departure') + '</div></div>';
			} else {
				dataline += '<div><div class="departure"></div></div>';
			}
			$('.moreinfo .mfooter').append('<div class="dataline">' + dataline + '</div>');
			if ($('.moreinfo .loading').length == 0) {
				$('.moreinfo .mfooter').append('<div class="loading">Lade Daten, bitte warten...</div>');
			}
			if (trainElem.data('moreinfo') != '') {
				var ibuf = '';
				for (var key in moreinfo) {
					ibuf += '<li>' + moreinfo[key] + '</li>';
				}
				$('.moreinfo .mfooter').append('Meldungen: <ul>' + ibuf + '</ul>');
			}
			var routebuf = '';
			if (trainElem.data('routeprev') != '') {
				for (var key in routeprev) {
					routebuf += '<li>' + routeprev[key] + '</li>';
				}
			}
			routebuf += '<li><strong>' + document.title + '</strong></li>';
			if (trainElem.data('routenext') != '') {
				for (var key in routenext) {
					routebuf += '<li>' + routenext[key] + '</li>';
				}
			}
			$('.moreinfo .mfooter').append('Fahrtverlauf: <ul class="mroute">' + routebuf + '</ul>');
		}
		$.get(window.location.href, {train: trainElem.data('train'), jid: trainElem.data('jid'), ajax: 1}, function(data) {
			$('.moreinfo').html(data);
		}).fail(function() {
			$('.moreinfo .mfooter').append('Der Zug ist abgefahren (Zug nicht gefunden)');
		});
		infoElem.removeClass('collapsed-moreinfo');
		infoElem.addClass('expanded-moreinfo');
	});
}

function dbf_reg_handlers() {
	$('div.app > ul > li').click(function(event) {
		const trainElem = $(this);
		const station = $('div.app').data('station');
		const param = new URLSearchParams(window.location.search);
		event.preventDefault();
		var suffix = '?';
		if (param.get('detailed')) {
			suffix += '&detailed=1';
		}
		if (param.get('efa') && param.get('efa') != '0') {
			suffix += '&efa=' + param.get('efa') + '&highlight=' + trainElem.data('station');
		}
		if (param.get('hafas') && param.get('hafas') != '0') {
			suffix += '&hafas=' + param.get('hafas') + '&highlight=' + trainElem.data('station');
		}
		if (param.get('past')) {
			suffix += '&past=1';
		}
		if (param.get('rt') || param.get('show_realtime')) {
			suffix += '&rt=1';
		}
		if (param.get('hafas') && param.get('hafas') != '0') {
			history.pushState({'page':'traindetail','jid':trainElem.data('jid')}, 'test', '/z/' + trainElem.data('jid') + suffix);
		} else if (param.get('efa') && param.get('efa') != '0') {
			history.pushState({'page':'traindetail','jid':trainElem.data('jid')}, 'test', '/z/' + trainElem.data('jid') + suffix);
		} else {
			history.pushState({'page':'traindetail','station':station,'train':trainElem.data('no')}, 'test', '/z/' + trainElem.data('train') + '/' + trainElem.data('station') + suffix);
		}
		dbf_show_moreinfo(trainElem, false);
	});
	const trainid = $(location).attr('hash').substr(1);
	if (trainid) {
		var found = false;
		$('div.app > ul > li').each(function(index) {
			if (found) {
				return;
			}
			$(this).find('.anchor').each(function() {
				if ($(this).attr('id') == trainid) {
					found = true;
				}
			});
		});
		if (found) {
			found = false;
			$('div.app > ul > li').each(function(index) {
				if (found) {
					return;
				}
				$(this).find('.anchor').each(function() {
					if ($(this).attr('id') == trainid) {
						found = true;
					}
				});
				if (found) {
					$(this).addClass('selected');
				} else {
					$(this).addClass('past');
				}
			});
		}
	}
}

$(function() {
	$('.moresettings-header').each(function() {
		$(this).click(function() {
			var moresettings = $('.moresettings');
			if ($(this).hasClass('moresettings-header-collapsed')) {
				$(this).removeClass('moresettings-header-collapsed');
				$(this).addClass('moresettings-header-expanded');
				moresettings.removeClass('moresettings-collapsed');
				moresettings.addClass('moresettings-expanded');
			}
			else {
				$(this).removeClass('moresettings-header-expanded');
				$(this).addClass('moresettings-header-collapsed');
				moresettings.removeClass('moresettings-expanded');
				moresettings.addClass('moresettings-collapsed');
			}
		});
	});
	$('.developers-header').each(function() {
		$(this).click(function() {
			var developers = $('.developers');
			if ($(this).hasClass('developers-header-collapsed')) {
				$(this).removeClass('developers-header-collapsed');
				$(this).addClass('developers-header-expanded');
				developers.removeClass('developers-collapsed');
				developers.addClass('developers-expanded');
			}
			else {
				$(this).removeClass('developers-header-expanded');
				$(this).addClass('developers-header-collapsed');
				developers.removeClass('developers-expanded');
				developers.addClass('developers-collapsed');
			}
		});
	});
	dbf_reg_handlers();
	if ($('.content .app').length) {
		setTimeout(reload_app, 30000);
		history.replaceState({'page':'station'}, document.title, '');
	}
	window.onpopstate = function(event) {
		if (event.state != null) {
			if ((event.state['page'] == 'station')) {
				$('.moreinfo').each(function() {
					$(this).removeClass('expanded-moreinfo');
					$(this).addClass('collapsed-moreinfo');
				});
				if (!$('div.app > ul').length) {
					$('div.app').append('<ul></ul>');
					reload_app();
				}
			} else if ((event.state['page'] == 'traindetail')) {
				var success = false;
				$('div.app > ul > li').each(function() {
					const trainElem = $(this);
					if (trainElem.data('no') == event.state['train']) {
						dbf_show_moreinfo(trainElem, true);
						success = true;
						return;
					}
				});
				if (!success) {
					$('.moreinfo').each(function() {
						$(this).removeClass('collapsed-moreinfo');
						$(this).addClass('expanded-moreinfo');
					});
					$('.moreinfo .mfooter').append('Der Zug ist abgefahren (Zug nicht gefunden)');
				}
			}
		} else {
			console.log("unhandled popstate! " + document.location);
		}
	};
});
