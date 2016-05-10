$(document).ready(function() {
	var processResult = function(data) {
		if (data.error) {
			$('div.candidatelist').text(data.error);
		} else {
			$.each(data.candidates, function(i, candidate) {

				var ds100 = candidate[0][0],
					name = candidate[0][1],
					distance = candidate[1];
				distance = distance.toFixed(1);

				var stationlink = $(document.createElement('a'));
				stationlink.attr('href', ds100);
				stationlink.text(name);
				$('div.candidatelist').append(stationlink);
			});
		}
	};

	var processLocation = function(loc) {
		$.post('/_geolocation', {lon: loc.coords.longitude, lat: loc.coords.latitude}, processResult);
	};

	if (navigator.geolocation) {
		navigator.geolocation.getCurrentPosition(processLocation);
	} else {
		$('div.candidatelist').text('Geolocation is not supported by your browser');
	}
});
