$(document).ready(function() {
	if (document.location.hash.length > 1) {
		var wanted = document.location.hash.replace('#', '');
		$('div.app > ul > li > .moreinfo, div.infoscreen > ul > li > .moreinfo').each(function() {
			if ($(this).data('train') == wanted) {
				$(this).removeClass('collapsed-moreinfo');
				$(this).addClass('expanded-moreinfo');
			}
		});
	}
	$('div.app > ul > li').click(function() {
		var trainElem = $(this);
		$('.moreinfo').each(function() {
			var infoElem = $(this);
			$('.moreinfo .train-line').text(trainElem.data('train'));
			$('.moreinfo .train-no').text('');
			$('.moreinfo .train-origin').text(trainElem.data('from'));
			$('.moreinfo .train-dest').text(trainElem.data('to'));
			$('.moreinfo .minfo').text('');
			$('.moreinfo .mfooter').html('<div style="text-align: center; width: 100%;">Lade Daten, bitte warten...</div>');
			$('.moreinfo .verbose').html('');
			$('.moreinfo .mroute').html('');
			$('.moreinfo ul').html('');
			$.get(window.location.href, {train: trainElem.data('train')}, function(data) {
				$('.moreinfo').html(data);
			}).fail(function() {
				$('.moreinfo .mfooter').html('Der Zug ist abgefahren (Zug nicht gefunden)');
			});
			infoElem.removeClass('collapsed-moreinfo');
			infoElem.addClass('expanded-moreinfo');
		});
	});
	$('.moreinfo').click(function() {
		$(this).removeClass('expanded-moreinfo');
		$(this).addClass('collapsed-moreinfo');
	});
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
});
