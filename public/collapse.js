$(document).ready(function() {
	$('div.displayclean > ul > li').each(function() {
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
});
