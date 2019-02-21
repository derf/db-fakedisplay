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
	$('div.app > ul > li, div.infoscreen > ul > li').each(function() {
		$(this).click(function() {
			$(this).children('.moreinfo').each(function() {
				if ($(this).hasClass('expanded-moreinfo')) {
					$(this).removeClass('expanded-moreinfo');
					$(this).addClass('collapsed-moreinfo');
					// Setting an empty hash causes the browser to scroll back
					// to the top -- we don't want that.
					var posX = window.pageXOffset;
					var posY = window.pageYOffset;
					document.location.hash = '';
					window.scrollTo(posX, posY);
				}
				else {
					$('.moreinfo').each(function() {
						if ($(this).hasClass('expanded-moreinfo')) {
							$(this).removeClass('expanded-moreinfo');
							$(this).addClass('collapsed-moreinfo');
						}
					});
					$(this).removeClass('collapsed-moreinfo');
					$(this).addClass('expanded-moreinfo');
					document.location.hash = $(this).data('train');
				}
			});
		});
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
