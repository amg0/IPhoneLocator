//# sourceURL=J_Phone.js
// for dynamic loaded script to appear in google debugger
var iphone_Svs = 'urn:upnp-org:serviceId:IPhoneLocator1';
var googleMap_refresh = 4000;
var ip_address = data_request_url;

//-------------------------------------------------------------
// Utilities Javascript
//-------------------------------------------------------------
var IPhoneLocator_Utils = (function() {
	function isFunction(x) {
	  return Object.prototype.toString.call(x) == '[object Function]';
	};
	function format(str)
	{
	   var content = str;
	   for (var i=1; i < arguments.length; i++)
	   {
			var replacement = new RegExp('\\{' + (i-1) + '\\}', 'g');	// regex requires \ and assignment into string requires \\,
			// if ($.type(arguments[i]) === "string")
				// arguments[i] = arguments[i].replace(/\$/g,'$');
			content = content.replace(replacement, arguments[i]);  
	   }
	   return content;
	};	
	function rgb2hex(r, g, b) {
		return "#" + (65536 * r + 256 * g + b).toString(16);
	};
	function escapeLuaPattern(val) {
		var result="";
		var chars = "( ) . % + - * ? ["; //^ $
		jQuery.each(chars.split(" "),function(idx,c) {
			esc_c = c.replace(/[-[\]{}()*+?.,\\^$|#\s]/g, "\\$&");
			val = val.replace( new RegExp(esc_c, 'g'),'%'+c);
		});
		return val;
	};
	//-------------------------------------------------------------
	// SYNCHRONOUS HTTP Get request , returns the responseText
	//-------------------------------------------------------------
	function getURL(url){
		return jQuery.ajax({
			type: "GET",
			url: url,
			cache: false,
			async: false
		}).responseText;
	};
	//-------------------------------------------------------------
	// Utilities for searching Vera devices
	//-------------------------------------------------------------
	function findDeviceIdx(deviceID) 
	{
		//jsonp.ud.devices
		for(var i=0; i<jsonp.ud.devices.length; i++) {
			if (jsonp.ud.devices[i].id == deviceID) 
				return i;
		}
		return null;
	};

	function findRootDeviceIdx(deviceID) 
	{
		var idx = IPhoneLocator_Utils.findDeviceIdx(deviceID);
		while (jsonp.ud.devices[idx].id_parent != 0)
		{
			idx = IPhoneLocator_Utils.findDeviceIdx(jsonp.ud.devices[idx].id_parent);
		}
		return idx;
	};

	function findRootDevice(deviceID)
	{
		var idx = IPhoneLocator_Utils.findRootDeviceIdx(deviceID) ;
		return jsonp.ud.devices[idx].id;
	};
	
	return {
		isFunction:isFunction,
		rgb2hex:rgb2hex,
		escapeLuaPattern:escapeLuaPattern,
		getURL:getURL,
		findDeviceIdx:findDeviceIdx,
		findRootDeviceIdx:findRootDeviceIdx,
		findRootDevice:findRootDevice
		//format:format,
	}
})();

//-------------------------------------------------------------
// getGoogleMapKey(deviceID) returns the key or ""
//-------------------------------------------------------------
function getGoogleMapKey( deviceID ) {
	var root = IPhoneLocator_Utils.findRootDevice(deviceID);
	var key = get_device_state(root,  iphone_Svs, 'GoogleMapKey',1);
	return key
}

//-------------------------------------------------------------
// getDevicePollingMap(deviceID) returns an array of distances
//-------------------------------------------------------------
function getDevicePollingMap(deviceID)
{
	// only roots have polling maps
	var root = IPhoneLocator_Utils.findRootDevice(deviceID);
    var auto= get_device_state(root,  iphone_Svs, 'PollingAuto',1);
    var pollmap = get_device_state(root,  iphone_Svs, 'PollingMap',1);
	if (pollmap=="_")
		pollmap="";
	var result = [];
	if (auto =="1") {
		var elems = pollmap.split(',')
		jQuery.each( elems, function(index,value) {
			var pair  = value.split(':');
			result.push(pair[0]);	// distance
		});
	}
	return result;
}

//-------------------------------------------------------------
// createPollingMap(home,base)
// - home is the data context object saved for persistence
//-------------------------------------------------------------
function createPollingMap(home,base)
{
	var idx=0;
	var distances = getDevicePollingMap(home.deviceID);
	jQuery.each( distances , function( key, value ) {
		home.pollingMap[idx] = new google.maps.Circle({
			center: base,
			fillColor: 'Aqua',
			fillOpacity: 0.2,
			map: home.map,
			radius:value*1000,
			strokeColor: IPhoneLocator_Utils.rgb2hex(0,0,0),
			strokeOpacity:1,
			strokeWeight:1,
			visible:jQuery( "#pollmap" )[0].checked
		});
		idx++;
	});
	return home.pollingMap;
}

//-------------------------------------------------------------
// createChildrenMarkers(home,base)
// - home is the data context object saved for persistence
//-------------------------------------------------------------
function getChildrenInfoMap(deviceID)
{
	var map = [];
	var root = IPhoneLocator_Utils.findRootDevice(deviceID);
	var thisid = IPhoneLocator_Utils.findDeviceIdx(deviceID) ;
	for(var i=0; i<jsonp.ud.devices.length; i++) {
		// add all children of that root
        if ((jsonp.ud.devices[i].id_parent == root) && (thisid!=i))
		{			
			var childid = jsonp.ud.devices[i].id;
			map.push({
				lat: get_device_state(childid,  iphone_Svs, 'CurLat',1),
				lng: get_device_state(childid,  iphone_Svs, 'CurLong',1),
				phonename: jsonp.ud.devices[i].name
			});
		}
    }
	// if the deviceID was not the root, we need to add the root device too
	if (deviceID != root) {
		map.push({
			lat: get_device_state(root,  iphone_Svs, 'CurLat',1),
			lng: get_device_state(root,  iphone_Svs, 'CurLong',1),
			phonename: jsonp.ud.devices[IPhoneLocator_Utils.findRootDeviceIdx(deviceID)].name
		});
	}
	return map;
}

function createChildrenMarkers(home,base)
{
	var idx=0;
	var childrenmap = getChildrenInfoMap(home.deviceID);
	home.children = new Array();
	jQuery.each(childrenmap, function(key,value) {
		home.children.push( new google.maps.Marker({
			position: new google.maps.LatLng(value.lat, value.lng),
			map: home.map,
			title:value.phonename,
			icon: 'http://maps.google.com/mapfiles/ms/icons/red-dot.png',
			visible:jQuery( "#showchild" )[0].checked
		}) );
	});
	return home.children;
}

//-------------------------------------------------------------
// Button Callbacks
//-------------------------------------------------------------
function centerToLocation(lat, lng){
	var center = new google.maps.LatLng(lat, lng);
	var home = 	jQuery( "#map_canvas" ).data( "home");
	var map = home.map;
	map.panTo(center);
};

function setPollingMapVisibility(home, checked )
{
	jQuery.each( home.pollingMap , function( key, value ) {
		value.setVisible( checked );
	});
}

function showChildren(home, checked )
{
	jQuery.each( home.children , function( key, value ) {
		value.setVisible( checked );
	});
}
	
//-------------------------------------------------------------
// Boot Strap CB code to dynamically load & create google map
// this method is called automatically when the script is 
// actually finished to be loaded
//-------------------------------------------------------------	
function handleApiReady() {
	// find context information
	var home = 	jQuery( "#map_canvas" ).data( "home");
	
	//NOTE to myself: window.clearInterval(interval);   can be used later on if needed
	
	if (home.interval==null) {
		var base = new google.maps.LatLng(home.homelat,home.homelong)//(-34.397, 150.644);
		var phone = new google.maps.LatLng(home.curlat,home.curlong)//(-34.397, 150.644);

		var myOptions = {
			zoom: 12,
			center: base,
			// disableDefaultUI: true,
			panControl: true,
			zoomControl: true,
			mapTypeControl: true,
			// mapTypeId: google.maps.MapTypeId.ROADMAP
		}
		
		home.map = new google.maps.Map(document.getElementById("map_canvas"), myOptions);
		// http://maps.google.com/mapfiles/ms/icons/blue-dot.png
		// http://maps.google.com/mapfiles/ms/icons/red-dot.png
		// http://maps.google.com/mapfiles/ms/icons/purple-dot.png
		// http://maps.google.com/mapfiles/ms/icons/yellow-dot.png
		// http://maps.google.com/mapfiles/ms/icons/green-dot.png
		var basemarker = new google.maps.Marker({
			position: base,
			map: home.map,
			draggable:true,
			icon: 'http://maps.google.com/mapfiles/ms/icons/green-dot.png',
			title:"Base"
		});
		
		var phonemarker = new google.maps.Marker({
			position: phone,
			map: home.map,
			icon: 'http://maps.google.com/mapfiles/ms/icons/red-dot.png',
			title:home.phonename
		});
		
		google.maps.event.addListener(basemarker, 'dragend', function(evt) {
			// find context 
			var home = 	jQuery( "#map_canvas" ).data( "home");
			
			// not strictly needed but for rigor
			home.homelat=evt.latLng.lat()
			home.homelong=evt.latLng.lng()
			
			// save on the device and will light up the 'save' button
			iphone_SetFloat(home.deviceID , 'HomeLat', evt.latLng.lat());
			iphone_SetFloat(home.deviceID , 'HomeLong', evt.latLng.lng());
			
			// update context
			jQuery( "#map_canvas" ).data( "home", home );
		});

		home.range = new google.maps.Circle({
			center: base,
			fillColor: 'LightSkyBlue',
			fillOpacity: 0.2,
			map: home.map,
			radius:home.range*1000,
			strokeColor: 'MediumBlue',
			strokeOpacity:0.5
		});
		home.range.setVisible( jQuery( "#range" )[0].checked );

		// create polling map and associated circles
		createPollingMap(home,base);
		createChildrenMarkers(home,base);
		
		home.interval = window.setInterval(function() { 
			// regular refresh, use dynamic mode in get_device_state
			var canvas = jQuery( "#map_canvas" );
			if (canvas.length>0) {
				var home = 	jQuery( "#map_canvas" ).data( "home");
				var deviceID = home.deviceID;
				var curlat = get_device_state(deviceID,  iphone_Svs, 'CurLat',1);
				var curlong= get_device_state(deviceID,  iphone_Svs, 'CurLong',1);
				var pos = new google.maps.LatLng(curlat, curlong);
				
				//home.range.setVisible( jQuery( "#range" ).checked );
				phonemarker.setPosition(pos);
				}
			}, 
			googleMap_refresh
		);
		
		// refresh context object
		jQuery( "#map_canvas" ).data( "home", home );
	}
}

//-------------------------------------------------------------
// Trigger the loading of the google map code if needed
//-------------------------------------------------------------	
function appendBootstrap(deviceID) {
	if(typeof google === 'object' && typeof google.maps === 'object'){
		setTimeout("handleApiReady()", 500);
	}
	else {
		var key = getGoogleMapKey(deviceID)
		var script = document.createElement("script");
		script.type = "text/javascript";
		script.src = "//maps.google.com/maps/api/js?callback=handleApiReady";
		if (key!="none") {
			script.src += "&key="+key
		}
		document.body.appendChild(script);
	}
}

//-------------------------------------------------------------
// Device TAB : Map
//		width: 520px;\
//		height: 337px;\
//-------------------------------------------------------------	
function iphone_Map(deviceID) {
	// first determine if it is a child device or not
	var device = IPhoneLocator_Utils.findDeviceIdx(deviceID);
	//var debug  = get_device_state(deviceID,  iphone_Svs, 'Debug',1);
	var root = (device!=null) && (jsonp.ud.devices[device].id_parent==0);
    var homelat = get_device_state(deviceID,  iphone_Svs, 'HomeLat',1);
    var homelong= get_device_state(deviceID,  iphone_Svs, 'HomeLong',1);
    var curlat = get_device_state(deviceID,  iphone_Svs, 'CurLat',1);
    var curlong= get_device_state(deviceID,  iphone_Svs, 'CurLong',1);
    var range = get_device_state(deviceID,  iphone_Svs, 'Range',1);
	var ui7 = get_device_state(deviceID,  iphone_Svs, 'UI7Check',1);
	var panelmargin = "-15px";
	if (ui7=="true") {
		panelmargin = "0px";
	}
	var name = jsonp.ud.devices[device].name;
	var showchildren = '<input id="showchild" type="checkbox" value="On">Show All<br>';
	html =  '					\
	<style>\
	  #tbl_map {\
		margin: '+panelmargin+';\
		padding: 0;\
	  }\
	  #tbl_map tbody tr td {\
		vertical-align:top;	\
	  }\
	  #map_canvas {\
		margin: 0px;\
		padding: 0;\
		width: 520px;\
		height: 337px;\
	  }\
	  .mapbutton {\
		width:100%; \
	  }\
	</style>\
	<table id="tbl_map"><tr>		\
	<td >			\
	<button id="center_home" type="button" class="mapbutton">Center Home</button>	\
	<button id="center_phone" type="button" class="mapbutton">Center Phone</button>	\
	<button id="full_screen" type="button" class="mapbutton">Full Screen</button>	\
	<input id="range" type="checkbox" value="On">Range<br> \
	<input id="pollmap" type="checkbox" value="On">Poll Map<br>'+showchildren+
	'<div><img src="http://maps.google.com/mapfiles/ms/icons/green-dot.png" >Base</img></div>'+
	'<div><img src="http://maps.google.com/mapfiles/ms/icons/red-dot.png" >iDevice(s)</img></div>'+
	'</td>'+
	'<td >					\
	<div id="map_canvas">	\
		map					\
	</div>					\
	</td></tr></table>';
	set_panel_html(html);
	// addSaveButtonForMap( deviceID );
	jQuery( "#map_canvas" ).data( "home", {
		deviceID: deviceID,
		phonename: name,
		homelat: homelat, 
		homelong: homelong,
		curlat: curlat, 
		curlong: curlong,
		interval: null,
		range: range,
		pollingMap: [],	// array of distances
		map: null
		} );

	appendBootstrap(deviceID);

	jQuery( "#range" ).change( function() {
		var home = 	jQuery( "#map_canvas" ).data( "home");
		home.range.setVisible( this.checked );
	});
	
	jQuery( "#pollmap" ).change( function() {
		var home = 	jQuery( "#map_canvas" ).data( "home");
		setPollingMapVisibility(home, this.checked );
	});
	
	jQuery( "#showchild" ).change( function() {
		var home = 	jQuery( "#map_canvas" ).data( "home");
		showChildren(home, this.checked );
	});

	jQuery( "#center_home" ).click( function() {
		centerToLocation(homelat,homelong);
	});

	jQuery( "#center_phone" ).click( function() {
		centerToLocation(curlat,curlong);
	});
	
	// http://maps.google.com/?q=MY%20LOCATION@lat,long
	// 
	jQuery( "#full_screen" ).click( function() {
		var mapurl = get_device_state(deviceID,  iphone_Svs, 'MapUrl',1);
		window.open(mapurl,"_blank");
	});
}

//-------------------------------------------------------------
// UI interactivity in the Device TAB : Settings
//-------------------------------------------------------------	
function getAppleNames( deviceID ) {
	var root = IPhoneLocator_Utils.findRootDevice(deviceID);
	var names = get_device_state(root,  iphone_Svs, 'ICloudDevices',1);
	return names.split(',');
}

function initializeAppleNames( deviceID ) {
	// first clean up all options
	jQuery('#iphone_NameSelect').removeAttr('disabled');
	jQuery( "#iphone_NameSelect option" ).remove()
	
	// then get the new ones
	var applenames=getAppleNames( deviceID  );
	jQuery.each( applenames, function( index, value ) {
		var option = new Option(value, value); 
		jQuery('#iphone_NameSelect').append(option);
	});

	// re-enable refresh button
	jQuery("#refresh_icloud").prop("disabled", false).text("Refresh");

	return applenames;
}

function addOptionToTarget(value,bEscape)
{
	if (value!='') {
		if (bEscape!==false)
			value = IPhoneLocator_Utils.escapeLuaPattern(value);
		var option = new Option(value, value); 
		jQuery('#iphone_NameTarget').append(option);
	}
}

function saveTargetNames(deviceID)
{
	// iterate on all option objects to get names
	var names = new Array();
	jQuery( "#iphone_NameTarget option" ).each(function() {
		names.push( jQuery(this).text() );
	});
	
	//potential weakness : we should add ^ and $ to beg and end of strings
	iphone_Set(deviceID, "IPhoneName", names.join());	// native js join()
	
	// since this needs a luup refresh anyhow, force it so we get the red save button
	// set_device_state (deviceID, iphone_Svs, "IPhoneName", names.join())
}

function updateForAuto(auto) {
	if (auto == "1") {
		// if no map then Polling base is valid , if map is specified it can be disabled, 
		// same for Polling Divider
		var mapspecified = (jQuery( ".mytbl #iphone_PollingMap ")[0].value.length>0);
		jQuery( ".mytbl #iphone_periodTxt , .mytbl #iphone_dividerTxt")
			.css('text-decoration', (mapspecified ? 'line-through' : ''));
		jQuery( ".mytbl #iphone_PollingBase , .mytbl #iphone_PollingDivider")
			.prop("disabled", (mapspecified ? true : false))
			//.attr('disabled', (mapspecified ? 'disabled' : ''))
			.css('background', (mapspecified ?'#cccccc':'#ffffff'));
		
		// in auto mode, Map is allways editable
		jQuery( ".mytbl #iphone_mapTxt")
			.css('text-decoration', '');
		jQuery( ".mytbl #iphone_PollingMap")
			.prop("disabled", false)
			.css('background', '#ffffff');
	} else 
	{
		// in non auto mode, Polling Divider and Polling Map are not used
		jQuery( ".mytbl #iphone_periodTxt")
			.css('text-decoration', '');
		jQuery( ".mytbl #iphone_PollingBase")
			.prop("disabled", false)
			.css('background', '#ffffff');
		jQuery( ".mytbl #iphone_dividerTxt , .mytbl #iphone_mapTxt")
			.css('text-decoration', 'line-through');
		jQuery( ".mytbl #iphone_PollingDivider , .mytbl #iphone_PollingMap")
			.prop("disabled", true)
			.css('background', '#cccccc');
	}
}

//-------------------------------------------------------------
// Management of the Save button
//-------------------------------------------------------------	
function showStatus(text, error)
{
	var e = jQuery("#status_display");
	e.show();
	e.html(text);
	e.css('background-color', (error ? '#FF9090' : '#90FF90'));
}

function clearStatus() {
	var e = jQuery("#status_display");
	e.html("Save");
	e.css('background-color', '');
	//e.hide();
}

//-------------------------------------------------------------
// Management of the TABS & Pannel
//-------------------------------------------------------------	
function clickPanelTab( o )	// must be called as event, this is the clicked "LI"
{
	jQuery( "li.tabs" ).removeClass("selected");
	jQuery(o).addClass("selected");
	showPanel();
}

function showPanel( )	// updates panel based on selected "LI"
{
	jQuery("li.tabs").each( function() {
		var o = jQuery(this)
		var id = o.attr("id");
		jQuery("div.tabs#"+id).toggle(o.hasClass("selected"))
	});
}

//-------------------------------------------------------------
// Device TAB : Settings
//-------------------------------------------------------------	
function iphone_Settings(deviceID) {
	// fix for UI5 where .prop does not exist
	if (jQuery.fn.prop == undefined)
	{
		jQuery.fn.prop=function ( name, value ) {
			if (name=="disabled") {
				return jQuery.access( this, name, value ? "disabled" : "", true, jQuery.attr );
			}
			console.log("undefined name passed to .prop:"+name);
		}
	}
	// first determine if it is a child device or not
	var device = IPhoneLocator_Utils.findDeviceIdx(deviceID);
	//var debug  = get_device_state(deviceID,  iphone_Svs, 'Debug',1);
	var root = (device!=null) && (jsonp.ud.devices[device].id_parent==0);
    var email  = get_device_state(deviceID,  iphone_Svs, 'Email',1);
    var password  = '' //get_device_state(deviceID,  iphone_Svs, 'Password',1);
    var name = get_device_state(deviceID,  iphone_Svs, 'IPhoneName',1);
    var period = get_device_state(deviceID,  iphone_Svs, 'PollingBase',1);
    var auto = get_device_state(deviceID,  iphone_Svs, 'PollingAuto',1);
	var pollingextra = get_device_state(deviceID,  iphone_Svs, 'PollingExtra',1);
    var divider = get_device_state(deviceID,  iphone_Svs, 'PollingDivider',1);
    var pollingmap = get_device_state(deviceID,  iphone_Svs, 'PollingMap',1);
	if (pollingmap=="_")
		pollingmap="";
    var homelat = get_device_state(deviceID,  iphone_Svs, 'HomeLat',1);
    var homelong= get_device_state(deviceID,  iphone_Svs, 'HomeLong',1);
    var range = get_device_state(deviceID,  iphone_Svs, 'Range',1);
	var unit = get_device_state(deviceID,  iphone_Svs, 'Unit',1);
	var distancemode = get_device_state(deviceID,  iphone_Svs, 'DistanceMode',1);
    var addrFormat = get_device_state(deviceID,  iphone_Svs, 'AddrFormat',1);
	var houseModeActor = get_device_state(deviceID,  iphone_Svs, 'HouseModeActor',1);
	var ui7 = get_device_state(deviceID,  iphone_Svs, 'UI7Check',1);
	var panelmargin = "-15px";
	if (ui7=="true") {
		panelmargin = "0px";
	}
	var navbar = "<ul class='tabs'> " +
	"<li id='tabs1' class='tabs selected'>Home</li>" + 
	((root==true) ?  "<li id='tabs2' class='tabs'>iCloud</li>" + "<li id='tabs3' class='tabs'>Polling</li>"+ "<li id='tabs4' class='tabs'>Donate</li>" +"</ul>" : '' );

	var unitselect = ' \
	<select id="myselect" onchange="iphone_SetUnit(' + deviceID + ', \'Unit\', this.value);"> \
	<option value="Km" '+((unit=="Km") ? 'selected' : '' ) +'>Kilometer</option>	\
    <option value="Mm" '+((unit=="Mm") ? 'selected' : '' ) +'>Statute Mile</option>	\
    <option value="Nm" '+((unit=="Nm") ? 'selected' : '' ) +'>Nautical Mile</option>	\
	</select>';
	
	var distancemodeselect = ' \
	<select id="dmselect" onchange="iphone_SetDM(' + deviceID + ', \'DistanceMode\', this.value);"> \
	<option value="direct" '+((distancemode=="direct") ? 'selected' : '' ) +'>direct</option>	\
	<option value="driving" '+((distancemode=="driving") ? 'selected' : '' ) +'>driving</option>	\
    <option value="walking" '+((distancemode=="walking") ? 'selected' : '' ) +'>walking</option>	\
    <option value="bicycling" '+((distancemode=="bicycling") ? 'selected' : '' ) +'>bicycling</option>	\
	</select>';
	
	var htmlnameselector = '<table> \
	<tr><td><select class="namebox" id="iphone_NameSelect" multiple></select></td><td><button id="button_copycloudname" type="button">==></button><button  id="refresh_icloud">Refresh</button></td><td><select class="namebox" id="iphone_NameTarget" multiple></select>	\
	<div class="floatcol">	\
	<button id="button_deletetarget" type="button">X</button> \
	<button id="button_up" type="button">Up</button>	\
	<button id="button_down" type="button">Down</button>	\
	</div>	\
	</td></tr> \
	<tr><td>Pattern:<input type="text" id="iphone_Pattern" size=15 value=""></td><td><button id="button_copypattern" type="button">==></button></td><td>(Comma separated list of iCloud Device name or <a target="_blank" href="http://www.lua.org/pil/20.2.html">Lua patterns</a>)</td></tr>	\
	</table>'
	
	var htmliCloud = 
		' <tr><td>iCloud Email:</td><td><input  type="text" id="iphone_Email" size=23 value="' +  email + '" onchange="iphone_SetEmail(' + deviceID + ', \'Email\', this.value);"></td><td>iCloud Password:<input type="password" id="iphone_Password" size=15 value="' +  password + '" onchange="iphone_SetPassword(' + deviceID + ', this.value);">Show:<input type="checkbox" name="showpwd" onclick="handleShowPwdCheckbox(this);" value="showpwd"></td></tr>'+
		'<tr><td>IPhone Name:</td><td colspan="2">'+htmlnameselector+'</td></tr>';

	var htmlPolling = '<tr><td id="iphone_periodTxt">Polling period:</td><td><input type="text" id="iphone_PollingBase" size=10 value="' +  period + '" onchange="iphone_SetInteger(' + deviceID + ', \'PollingBase\', this.value);">Dynamic:<input type="checkbox" name="auto" onclick="handleAutoCheckbox(' + deviceID + ', \'PollingAuto\', this);" value="auto" '+(auto=="1"?'checked':'')+'></td><td>(iCloud Polling period in sec, or 0 to disable)</td></tr>' +
		'<tr><td>Distance Mode:</td><td>'+distancemodeselect+'</td><td>(use gps direct distance, or google map itinerary calculated distance)</td></tr>'+
		'<tr><td id="iphone_dividerTxt">Polling Divider:</td><td><input  type="text" id="iphone_PollingDivider" size=10 value="' +  divider + '" onchange="iphone_SetPollingDivider(' + deviceID + ', \'PollingDivider\', this.value);"> </td><td>(Divider of the estimated time of arrival for polling)</td></tr>'+
		'<tr><td id="iphone_mapTxt">Polling Map:</td><td><input  type="text" id="iphone_PollingMap" size=23 value="' +  pollingmap + '" onchange="iphone_SetPollingMap(' + deviceID + ', \'PollingMap\', this.value);"> </td><td>(Keep map empty for automatic polling calculation based on google reported ETA divided in chunks and Polling period at home. Or override for your own polling steps, based on a CSV set of distances like: dd:pp,dd:pp)</td></tr>' +
		'<tr><td id="iphone_pollExtra">Extra Polling:</td><td><input type="checkbox" name="pollingextra" onclick="handleCheckbox(' + deviceID + ', \'PollingExtra\', this);" value="pollingextra" '+(pollingextra=="1"?'checked':'')+'></td><td>(Poll iCloud twice with a few second interval to get maximum precision)</td></tr>';

	var htmlHome = ' <tr><td>Home Lat:</td><td><input type="text" id="iphone_HomeLat" size=23 value="' +  homelat +
		'" onchange="iphone_SetFloat(' + deviceID + ', \'HomeLat\', this.value);"></td><td>(dd.dddddd >0 for North, <0 for South)</td></tr>' +
        ' <tr><td>Home Long:</td><td><input type="text" id="iphone_HomeLong" size=23 value="' +  homelong + '" onchange="iphone_SetFloat(' + deviceID + ', \'HomeLong\', this.value);"></td><td>(dd.dddddd  >0 for East, <0 for West)</td></tr>' +
        ' <tr><td>Home Range:</td><td><input type="text" id="iphone_Range" size=3 value="' +  range+ '" onchange="iphone_SetFloat(' + deviceID + ', \'Range\', this.value);">:'+unitselect+'</td><td>(nn.nn, Max Distance from Home)(Nm:nautical Mm:mile Km:km)</td></tr>' +
        ' <tr><td>Participates in House Mode:</td><td><input type="checkbox" name="iphone_housemodeactor" onclick="handleCheckbox(' + deviceID + ', \'HouseModeActor\', this);" value="iphone_housemodeactor" '+(houseModeActor=="1"?'checked':'')+'></td><td>if this device participates in the HouseMode calculation.</td></tr>' +
        ' <tr><td>Addr Format:</td><td><input type="text" id="iphone_AddrFormat" size=23 value="' +  addrFormat+ '" onchange="iphone_SetAddr(' + deviceID + ', \'AddrFormat\', this.value);"></td><td>(empty or 0 for privacy. or CSV list of indexes or \'~\' followed by  template variables between { } like "~{street_number} {route},{postal_code} {locality}, {country}". See:<a target="_blank" href="https://developers.google.com/maps/documentation/geocoding/?hl=fr#Types">variables</a>. <br><strong>WARNING</strong>:\'~\' only supported if your distance mode in Polling Tab is: \'direct\'.)</td></tr>';

	var htmlDonate='<tr><td></td><td>For those who really like this plugin and feel like it, you can donate what you want here on Paypal. It will not buy you more support not any garantee that this can be maintained or evolve in the future but if you want to show you are happy and would like my kids to transform some of the time I steal from them into some <i>concrete</i> returns, please feel very free ( and absolutely not forced to ) to donate whatever you want.  thank you !'+ 
'<hr><form action="https://www.paypal.com/cgi-bin/webscr" method="post" target="_top">'+
'<input type="hidden" name="cmd" value="_s-xclick">'+
'<input type="hidden" name="encrypted" value="-----BEGIN PKCS7-----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-----END PKCS7-----">'+
'<input type="image" src="https://www.paypalobjects.com/en_US/i/btn/btn_donateCC_LG.gif" border="0" name="submit" alt="PayPal - The safer, easier way to pay online!">'+
'<hr><input type="image" src="https://www.paypalobjects.com/fr_FR/FR/i/btn/btn_donateCC_LG.gif" border="0" name="submit" alt="PayPal - la solution de paiement en ligne la plus simple et la plus sécurisée !"><img alt="" border="0" src="https://www.paypalobjects.com/fr_FR/i/scr/pixel.gif" width="1" height="1">'+
'<img alt="" border="0" src="https://www.paypalobjects.com/fr_FR/i/scr/pixel.gif" width="1" height="1">'+
'</form>'+
'</td></tr>';
	// ul.tabs li.tabs { ==> background-color:#6495ED;					\
	// ul.tabs li.tabs.selected { ==> background-color:#D3D3D3;			\
		
    var style = '<style>\
			.namebox {\
				width:180px;\
				float:left:	\
			}\
			div.tabs {				\
				clear:left;			\
			}						\
			ul.tabs {				\
				 padding:0;			\
				 margin:0;			\
				 list-style-type:none;	\
			 }						\
			ul.tabs li.tabs {	\
			 line-height: 20px;	\
			 text-align: center;	\
			 color: #025cb6;	\
			 cursor: pointer;	\
			 display:block;								\
			 float:left;   								\
			 width:100px;								\
			 height:23px;								\
			 padding:0 5px;								\
			 background:url(/cmh/skins/default/images/cpanel/newbutton_bg.png?*~BUILD_VERSION~*) repeat-x top #f6fbfc;	\
			 text-decoration:none;						\
			 text-align:center;							\
			 border:1px solid;							\
			 border-color:#DCDCDC #696969 #696969 #DCDCDC;	\
			}					\
			ul.tabs li.tabs.selected {	\
			 border-color:#696969 #DCDCDC #DCDCDC #696969;		\
			 border-bottom: 1px solid #f6fbfc;				\
			 background:url(/cmh/skins/default/images/cpanel/button_bg.png?*~BUILD_VERSION~*) repeat-x top #f6fbfc;	\
			}		\
			div.floatcol {	\
				float:right;	\
			}	\
			div.floatcol button {	\
				display: block;	\
			}	\
			#pane {\
				margin: '+panelmargin+';\
				padding: 0;\
			} \
			#status_display {\
				//margin: 0px 0px 0px 0px;\
				cursor: pointer; \
				font-weight: bold; \
				// text-align:center; \
				// vertical-align:middle; \
				// color:black; \
				// height:21px; \
			}\
			table.mytbl {\
				margin: 0px;\
				padding: 0;\
			}\
		</style> ';
		
	var html = style+
		'<div class="pane" id="pane"> '+ navbar +
		'<div class="tabs" id="tabs1"> <table class="mytbl" width="100%">'+htmlHome+ '</table></div>' +
		'<div class="tabs" id="tabs2"> <table class="mytbl" width="100%">' + ((root==true) ? htmliCloud : '' ) + '</table></div>' +
		'<div class="tabs" id="tabs3"> <table class="mytbl" width="100%">' + ((root==true) ? htmlPolling : '' )+ '</table></div>' +
		'<div class="tabs" id="tabs4"> <table class="mytbl" width="100%">' + ((root==true) ? htmlDonate : '' )+ '</table></div>' +
		'</div>' ;

	set_panel_html(html);
	jQuery( "table.mytbl td:nth-child(1)" ).css({"white-space":"nowrap"});
	// addSaveButton( deviceID );
	showPanel();
	jQuery( "li.tabs" ).click(function() {
		clickPanelTab(this);
	});

	if (root) {
		// initialize the list of possible apple names 
		initializeAppleNames(deviceID);

		// and initialize the target list from the names already saved in the device
		jQuery.each( name.split(','), function( index,value) {
			addOptionToTarget(value,false);
		});
	
		// click  handler to get pattern value and add it to target names 
		jQuery("#refresh_icloud").click( function() {
			// disable refresh button
			jQuery("#refresh_icloud").prop("disabled", true).text("Refreshing...");
			// first clean up all options
			jQuery( "#iphone_NameSelect option" ).remove();
			var option = new Option("Refresh...", "Refresh..."); 
			jQuery('#iphone_NameSelect').append(option);
			jQuery('#iphone_NameSelect').prop("disabled", true);
			ForceRefreshDevice(deviceID , initializeAppleNames);
		});
	
		// click  handler to get pattern value and add it to target names 
		jQuery( "#button_copypattern" ).click(function() {
			var value = jQuery( "#iphone_Pattern" )[0].value;
			addOptionToTarget(value);
			saveTargetNames(deviceID);
		});

		// click  handler to get selected names and add it to target names 
		jQuery( "#button_copycloudname" ).click(function() {
			jQuery( "#iphone_NameSelect option:selected" ).each(function() {
				var text =jQuery(this).text();
				text = text.replace(/\(/g, "\\(");
				text = text.replace(/\)/g, "\\)");
				addOptionToTarget("^"+text+"$");
			});
			saveTargetNames(deviceID);
		});

		// click handler to remove the selection from the target list ( delete button )
		jQuery( "#button_deletetarget" ).click(function() {
			jQuery( "#iphone_NameTarget option:selected" ).remove()
			saveTargetNames(deviceID);
		});

		// click handlers to move up or down selection
		jQuery( "#button_up" ).click(function() {
		  jQuery('#iphone_NameTarget option:selected').each(function(){
		   jQuery(this).insertBefore(jQuery(this).prev());
		  });
			saveTargetNames(deviceID);
		});
		
		jQuery( "#button_down" ).click(function() {
		  jQuery('#iphone_NameTarget option:selected').each(function(){
		   jQuery(this).insertAfter(jQuery(this).next());
		  });
			saveTargetNames(deviceID);
		});
	
		// update UI gadgets according to the polling auto selection mode
		updateForAuto(auto);
	}
	
}

//-------------------------------------------------------------
// Save functions
//-------------------------------------------------------------	
function handleCheckbox(deviceID, varName, cb) {
	return save(deviceID, varName, cb.checked?"1":"0");
}
function handleAutoCheckbox(deviceID, varName, cb) {
	updateForAuto(cb.checked?"1":"0");
	handleCheckbox(deviceID, varName, cb);
}
function handleShowPwdCheckbox(cb) {
	jQuery(".mytbl #iphone_Password")[0].type=(cb.checked?"text":"password");
}
function iphone_Set(deviceID, varName, varVal) {
	return save(deviceID, varName, varVal );
}

// iphone_SetPassword(deviceID,pwd) 
// is special, it saves immediately using the Plugin Handler channel to pass
// a command to the plugin
function iphone_SetPassword(deviceID,pwd) {
    var email  = jQuery('#iphone_Email').val();	//get_device_state(deviceID,  iphone_Svs, 'Email',1);
	var url = buildIPhoneHandlerUrl(deviceID,"SetCredentials",{email:email,pwd:pwd});
	
	// first clean up all options and block refresh button
	jQuery('#iphone_NameSelect').removeAttr('disabled');
	jQuery( "#iphone_NameSelect option" ).remove();
	jQuery("#refresh_icloud").prop("disabled", true).text("Refreshing...");
	
	// execute and get the result (table of names) - synchronous
	jQuery.ajax({
		type: "GET",
		url: url,
		cache: false,
		complete: function() {
			// restore refresh button
			jQuery("#refresh_icloud").prop("disabled", false).text("Refresh");
		}
	}).done(function(data, textStatus, jqXHR) {
		// then get the new ones
		// text result is a json encoding of array of iCloud names
		var applenames = JSON.parse(data);
		jQuery.each( applenames, function( index, value ) {
			var option = new Option(value, value); 
			jQuery('#iphone_NameSelect').append(option);
		});
	}).fail(function() {
		alert('Refresh Failed!');
	});
	return true;
}

function iphone_SetAddr(deviceID, varName, varVal) {
	return save(deviceID, varName, varVal, goodAddr );
}

function iphone_SetPollingMap(deviceID, varName, varVal) {
    var auto = get_device_state(deviceID,  iphone_Svs, 'PollingAuto',1);
	updateForAuto(auto);
	if (varVal=='')
		varVal='_';
	return save(deviceID, varName, varVal, goodPollMap );
}

function iphone_SetPollingDivider(deviceID, varName, varVal) {
	return save(deviceID, varName, varVal, goodnonzeroint );
}

function iphone_SetFloat(deviceID, varName, varVal) {
	return save(deviceID, varName, varVal, goodfloat);
}

function iphone_SetUnit(deviceID, varName, varVal) {
	return save(deviceID, varName, varVal, goodunit);
}

function iphone_SetDM(deviceID, varName, varVal) {
	return save(deviceID, varName, varVal, gooddistancemode);
}

function iphone_SetInteger(deviceID, varName, varVal) {
	return save(deviceID, varName, varVal, goodint);
}

function iphone_SetEmail(deviceID, varName, varVal) {
	return save(deviceID, varName, varVal, goodemail);
}

function save(deviceID, varName, varVal, func) {
    if ((!func) || func(varVal)) {
        //set_device_state(deviceID,  iphone_Svs, varName, varVal);
		saveVar(deviceID,  iphone_Svs, varName, varVal)
        jQuery('#iphone_' + varName).css('color', 'black');
    } else {
        jQuery('#iphone_' + varName).css('color', 'red');
		alert(varName+':'+varVal+' is not correct');
    }
}

//-------------------------------------------------------------
// Pattern Matching functions
//-------------------------------------------------------------	
function goodPollMap(v)
{
	var reg = new RegExp('^(([0-9]+(\.[0-9]+)*:[0-9]+)+(,([0-9]+(\.[0-9]+)*:[0-9]+)+)*|_)$','i');
	return(reg.test(v));
}

function goodAddr(v)
{
	var reg = new RegExp('^((([1-7],)*[1-7]|0|)|~[^{]*({[^{]+}[^{]*)*)$','i');
	return(reg.test(v));
}

function goodfloat(v)
{
	var reg = new RegExp('^-?[0-9]*[.][0-9]+$', 'i');
	return(reg.test(v));
}

function goodunit(v)
{
	var reg = new RegExp('^(Km|Mm|Nm)$', '');
	return(reg.test(v));
}

function gooddistancemode(v)
{
	var reg = new RegExp('^(direct|driving|walking|bicycling)$', '');
	return(reg.test(v));
}

function goodnonzeroint(v)
{
	var reg = new RegExp('^[0-9]+$', 'i');
	return((v!=0) && reg.test(v));
}

function goodint(v)
{
	var reg = new RegExp('^[0-9]+$', 'i');
	return(reg.test(v));
}

function goodemail(email)
{
	// @duiffie contribution
	var reg = new RegExp('^[_a-z0-9-]+(\.[_a-z0-9-]+)*@[a-z0-9-]+(\.[a-z0-9-]+)*(\.[a-z]{2,6})$', 'i');
	//var reg = new RegExp('^[a-z0-9]+[_|\.|-]?([a-z0-9_]+)*@[a-z0-9]+([_|\.|-]{1}[a-z0-9]+)*[\.]{1}[a-z]{2,6}$', 'i');
	return(reg.test(email));
}

//-------------------------------------------------------------
// Variable saving 
//-------------------------------------------------------------
function saveVar(deviceID,  service, varName, varVal)
{
	if (typeof(g_ALTUI)=="undefined") {
		//Vera
		if (api != undefined ) {
			api.setDeviceState(deviceID, service, varName, varVal,{dynamic:false})
			api.setDeviceState(deviceID, service, varName, varVal,{dynamic:true})
		}
		else {
			set_device_state(deviceID, service, varName, varVal, 0);
			set_device_state(deviceID, service, varName, varVal, 1);
		}
		var url = buildVariableSetUrl( deviceID, service, varName, varVal)
		jQuery.get( url )
			.done(function(data) {
			})
			.fail(function() {
				alert( "Save Variable failed" );
			})
	} else {
		//Altui
		set_device_state(deviceID, service, varName, varVal);
	}
}

//-------------------------------------------------------------
// Helper functions to build URLs to call VERA code from JS
//-------------------------------------------------------------

function buildVariableSetUrl( deviceID, service, varName, varValue)
{
	var urlHead = '' + ip_address + 'id=variableset&DeviceNum='+deviceID+'&serviceId='+service+'&Variable='+varName+'&Value='+varValue;
	return encodeURI(urlHead);
}

function buildUPnPActionUrl(deviceID,service,action)
{
	var urlHead = ip_address +'id=action&output_format=json&DeviceNum='+deviceID+'&serviceId='+service+'&action='+action;//'&newTargetValue=1';
	return encodeURI(urlHead);
}

//---------------------------------------------------------------------------
// buildIPhoneHandlerUrl(deviceID,command,params)
// IPhone_Handler is a generic entry point for sending commands to the plugin
// DeviceNum: is the number of the device ( vera index )
// command:  is the keyword for the command to call ( like SetPassword )
// params: is an array of parameters to add 
// RETURNS : the url
//---------------------------------------------------------------------------
function buildIPhoneHandlerUrl(deviceID,command,params)
{
	//http://192.168.1.5:3480/data_request?id=lr_IPhone_Handler
	var urlHead = ip_address +'id=lr_IPhone_Handler&command='+command+'&DeviceNum='+deviceID;
	jQuery.each(params, function(index,value) {
		urlHead = urlHead+"&"+index+"="+encodeURIComponent(value);
	});
	return encodeURI(urlHead);
}

//-------------------------------------------------------------
// Device Actions
// if a cbfunc is passed, it will be called asynchronously when 
// the ajax call returns successfull data. 
// in that case the function just rest "async"
//
// otherwise ( no cbfunc) the call is a synchronous GET
//-------------------------------------------------------------
function ForceRefreshDevice(deviceID, cbfunc)
{
	var url = buildUPnPActionUrl(deviceID,iphone_Svs,'ForceRefresh');
	if (IPhoneLocator_Utils.isFunction(cbfunc)) {
		jQuery.ajax({
			type: "GET",
			url: url,
			cache: false,
		}).done(function() {
			return cbfunc(deviceID)
		}).fail(function() {
			alert('Refresh Failed!');
			return null;
		});
	}
	else
		return IPhoneLocator_Utils.getURL(url);
	return "async";
}
