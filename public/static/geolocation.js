$(document).ready(function() {
	var removeStatus = function() {
		$('div.candidatestatus').remove();
	};

	var processResult = function(data) {
		removeStatus();
		if (data.error) {
			$('div.candidatelist').text(data.error);
		} else if (data.candidates.length == 0) {
			$('div.candidatelist').text("Keine Bahnhöfe in 70km Umkreis gefunden");
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
		$('div.candidatestatus').text('Suche Bahnhöfe…');
	};

	var processError = function(error) {
		removeStatus();
		if (error.code == error.PERMISSION_DENIED) {
			$('div.candidatelist').text('Geolocation request denied');
		} else if (error.code == error.POSITION_UNAVAILABLE) {
			$('div.candidatelist').text('Geolocation not available');
		} else if (error.code == error.TIMEOUT) {
			$('div.candidatelist').text('Geolocation timeout');
		} else {
			$('div.candidatelist').text('Unknown error');
		}
	};

	if (navigator.geolocation) {
		navigator.geolocation.getCurrentPosition(processLocation, processError);
		$('div.candidatestatus').text('Position wird bestimmt…');
	} else {
		removeStatus();
		$('div.candidatelist').text('Geolocation is not supported by your browser');
	}
});
