function reload_app() {
	$.get(window.location.href, {ajax: 1}, function(data) {
		$('div.app > ul').html(data);
		dbf_reg_handlers();
		setTimeout(reload_app, 60000);
	}).fail(function() {
		setTimeout(reload_app, 10000);
	});
}

function dbf_reg_handlers() {
	$('div.app > ul > li').click(function() {
		var trainElem = $(this);
		var routeprev = trainElem.data('routeprev').split('|');
		var routenext = trainElem.data('routenext').split('|');
		var moreinfo = trainElem.data('moreinfo').split('|');
		$('.moreinfo').each(function() {
			var infoElem = $(this);
			$('.moreinfo .train-line').removeClass('bahn sbahn fern ext').addClass(trainElem.data('linetype'));
			$('.moreinfo .train-line').text(trainElem.data('line'));
			$('.moreinfo .train-no').text(trainElem.data('no'));
			$('.moreinfo .train-origin').text(trainElem.data('from'));
			$('.moreinfo .train-dest').text(trainElem.data('to'));
			$('.moreinfo .minfo').text('');
			$('.moreinfo .mfooter').html('');
			$('.moreinfo .verbose').html('');
			$('.moreinfo .mroute').html('');
			$('.moreinfo ul').html('');
			var timebuf = '';
			if (trainElem.data('arrival') != '') {
				timebuf += '<div class="arrival">An: ' + trainElem.data('arrival') + '</div>';
			}
			if (trainElem.data('departure') != '') {
				timebuf += '<div class="departure">Ab: ' + trainElem.data('departure') + '</div>';
			}
			if (trainElem.data('platform') != '') {
				$('.moreinfo .mfooter').append('<div class="platforminfo">Gleis ' + trainElem.data('platform') + timebuf + '</div>');
			}
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
			$.get(window.location.href, {train: trainElem.data('train'), ajax: 1}, function(data) {
				$('.moreinfo').html(data);
			}).fail(function() {
				$('.moreinfo .mfooter').append('Der Zug ist abgefahren (Zug nicht gefunden)');
			});
			infoElem.removeClass('collapsed-moreinfo');
			infoElem.addClass('expanded-moreinfo');
		});
	});
}

$(function() {
	if (document.location.hash.length > 1) {
		var wanted = document.location.hash.replace('#', '');
		$('div.app > ul > li > .moreinfo, div.infoscreen > ul > li > .moreinfo').each(function() {
			if ($(this).data('train') == wanted) {
				$(this).removeClass('collapsed-moreinfo');
				$(this).addClass('expanded-moreinfo');
			}
		});
	}
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
	$('.moreinfo').click(function() {
		$(this).removeClass('expanded-moreinfo');
		$(this).addClass('collapsed-moreinfo');
	});
	dbf_reg_handlers();
	if ($('.content .app').length) {
		setTimeout(reload_app, 30000);
	}
});
