$(document).ready(function() {
	$('div.app > ul > li, div.infoscreen > ul > li').each(function() {
		$(this).click(function() {
			$(this).children('.moreinfo').each(function() {
				if ($(this).hasClass('expanded-moreinfo')) {
					$(this).removeClass('expanded-moreinfo');
					$(this).addClass('collapsed-moreinfo');
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
});
