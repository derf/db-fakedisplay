var j_reqid;
//var j_stops = [];
var j_positions = [];
var j_frame = [];
var j_frame_i = [];

function dbf_map_parse() {
	$('#jdata').each(function() {
		j_reqid = $(this).data('req');
		/*var route_data = $(this).data('route');
		if (route_data) {
			route_data = route_data.split('|');
			j_stops = [];
			for (var stop_id in route_data) {
				var stopdata = route_data[stop_id].split(';');
				for (var i = 1; i < 5; i++) {
					stopdata[i] = parseInt(stopdata[i]);
				}
				j_stops.push(stopdata);
			}
		}*/
		var positions = $(this).data('poly');
		if (positions) {
			positions = positions.split('|');
			j_positions = [];
			for (var pos_id in positions) {
				var posdata = positions[pos_id].split(';');
				posdata[0] = parseFloat(posdata[0]);
				posdata[1] = parseFloat(posdata[1]);
				j_positions.push(posdata);
			}
		}
	});
}

function dbf_anim_coarse() {
	if (j_positions.length) {
		var pos1 = marker.getLatLng();
		var pos1lat = pos1.lat;
		var pos1lon = pos1.lng;
		var pos2 = j_positions.shift();
		var pos2lat = pos2[0];
		var pos2lon = pos2[1];

		j_frame_i = 200;
		j_frame = [];

		// approx 30 Hz -> 60 frames per 2 seconds
		for (var i = 1; i <= 60; i++) {
			var ratio = i / 60;
			j_frame.push([pos1lat + ((pos2lat - pos1lat) * ratio), pos1lon + ((pos2lon - pos1lon) * ratio)]);
		}

		j_frame_i = 0;
	}
}

function dbf_anim_fine() {
	if (j_frame[j_frame_i]) {
		marker.setLatLng(j_frame[j_frame_i++]);
	}
}

function dbf_map_reload() {
	$.get('/_ajax_mapinfo/' + j_reqid, function(data) {
		$('#infobox').html(data);
		dbf_map_parse();
		setTimeout(dbf_map_reload, 61000);
	}).fail(function() {
		setTimeout(dbf_map_reload, 5000);
	});
}

$(document).ready(function() {
	if ($('#infobox').length) {
		dbf_map_parse();
		setInterval(dbf_anim_coarse, 2000);
		setInterval(dbf_anim_fine, 33);
		setTimeout(dbf_map_reload, 61000);
	}
});
