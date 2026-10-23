'use strict';

const fs = require('fs');

const LOG_FILE = '/tmp/cloudflarespeedtest.log';
const ENDPOINT = 'https://api.cloudflare.com/client/v4';

function command_output(cmd) {
	let pipe = fs.popen(cmd, 'r');
	let out = '';

	if (pipe) {
		out = pipe.read('all') || '';
		pipe.close();
	}

	return out;
}

function shquote(value) {
	return "'" + replace('' + value, "'", "'\\''") + "'";
}

function now_local() {
	return trim(command_output('date "+%Y-%m-%d %H:%M:%S"'));
}

function echolog(message) {
	let fd = fs.open(LOG_FILE, 'a');

	if (fd) {
		fd.write(now_local() + ': ' + message + '\n');
		fd.close();
	}
}

function urlencode(value) {
	value = '' + (value ?? '');

	return replace(value, /([^A-Za-z0-9._~-])/g, (m, c) => sprintf('%%%02X', ord(c)));
}

function json_escape(value) {
	value = '' + (value ?? '');

	return replace(replace(value, /\\/g, '\\\\'), /"/g, '\\"');
}

function cf_request(auth, method, path, query, body) {
	let url = ENDPOINT + path;

	if (length(query) > 0) {
		let encoded = [];

		for (let q in query)
			push(encoded, urlencode(q.key) + '=' + urlencode(q.value));

		url += '?' + join('&', encoded);
	}

	let cmd = 'curl -sSL --connect-timeout 5 -X ' + method;

	for (let header in auth.headers)
		cmd += ' -H ' + shquote(header);

	cmd += ' -H ' + shquote('Content-Type: application/json');

	if (body != null)
		cmd += ' -d ' + shquote(body);

	cmd += ' ' + shquote(url) + ' 2>&1';

	let response = command_output(cmd);

	try {
		return {
			raw: response,
			body: json(response)
		};
	}
	catch (e) {
		return {
			raw: response,
			body: null
		};
	}
}

function make_auth(app_key, app_secret) {
	/* Global API Key mode when an e-mail is given, Bearer API Token otherwise */
	if (app_key != '' && match(app_key, /@/))
		return {
			headers: [
				'X-Auth-Email: ' + app_key,
				'X-Auth-Key: ' + app_secret
			]
		};

	return {
		headers: [ 'Authorization: Bearer ' + app_secret ]
	};
}

function log_response_error(action, result) {
	let body = result.body;
	let errors = body?.errors;

	if (errors && length(errors) > 0) {
		for (let err in errors)
			echolog(action + ' failed: ' + (err.code ?? 'unknown') + ' ' + (err.message || ''));
	}
	else if (!result.raw)
		echolog(action + ' failed: empty response');
	else
		echolog(action + ' failed: ' + result.raw);
}

function has_error(result) {
	return !(result.body && result.body.success);
}

function find_zone_id(auth, main_domain) {
	let result = cf_request(auth, 'GET', '/zones', [
		{ key: 'name', value: main_domain },
		{ key: 'per_page', value: '50' }
	]);

	if (has_error(result)) {
		log_response_error('QUERY zone ' + main_domain, result);
		return null;
	}

	let zones = result.body?.result || [];

	if (type(zones) == 'object')
		zones = [ zones ];

	for (let zone in zones)
		if (lc(zone.name || '') == lc(main_domain))
			return '' + zone.id;

	echolog('QUERY zone ' + main_domain + ' failed: zone not found in this Cloudflare account');
	return null;
}

function list_records(auth, zone_id, full_domain, record_type) {
	let result = cf_request(auth, 'GET', '/zones/' + zone_id + '/dns_records', [
		{ key: 'name', value: full_domain },
		{ key: 'type', value: record_type },
		{ key: 'per_page', value: '100' }
	]);

	if (has_error(result)) {
		log_response_error('QUERY record ' + record_type + ' ' + full_domain, result);
		return null;
	}

	let records = result.body?.result || [];

	if (type(records) == 'object')
		records = [ records ];

	let ids = [];

	for (let record in records)
		if (record.id)
			push(ids, '' + record.id);

	return ids;
}

function record_body(record_type, full_domain, ip, proxied) {
	return '{"type":"' + record_type +
		'","name":"' + json_escape(full_domain) +
		'","content":"' + json_escape(ip) +
		'","ttl":1,"proxied":' + (proxied ? 'true' : 'false') + '}';
}

function main(argv) {
	if (length(argv) < 7) {
		echolog('# ERROR, Missing arguments');
		return 1;
	}

	if (system('command -v curl >/dev/null 2>&1') != 0) {
		echolog('# ERROR, curl command not found');
		return 1;
	}

	let app_key = argv[0];
	let app_secret = argv[1];
	let main_domain = argv[2];
	let sub_domain = argv[3];
	let is_ipv6 = argv[4];
	let proxied = (argv[5] == '1');
	let record_type = (is_ipv6 == '1') ? 'AAAA' : 'A';
	let full_domain = (sub_domain == '@') ? main_domain : sub_domain + '.' + main_domain;

	if (app_secret == '') {
		echolog('# ERROR, Cloudflare API token or Global API Key is empty');
		return 1;
	}

	let auth = make_auth(app_key, app_secret);
	let zone_id = find_zone_id(auth, main_domain);

	if (!zone_id)
		return 1;

	let ids = list_records(auth, zone_id, full_domain, record_type);

	if (ids == null)
		return 1;

	let failed = false;
	let ip_count = 0;

	for (let i = 6; i < length(argv); i++) {
		let ip = argv[i];

		if (!ip)
			continue;

		let record_id = ids[ip_count++];
		let action = record_id ? 'UPDATE' : 'ADD';
		let result = record_id
			? cf_request(auth, 'PUT', '/zones/' + zone_id + '/dns_records/' + record_id, null,
				record_body(record_type, full_domain, ip, proxied))
			: cf_request(auth, 'POST', '/zones/' + zone_id + '/dns_records', null,
				record_body(record_type, full_domain, ip, proxied));

		if (has_error(result)) {
			log_response_error(action + ' record ' + record_type + ' ' + ip, result);
			failed = true;
		}
		else {
			echolog(action + ' record ' + (result.body?.result?.id || record_id || '') + ' ' + record_type + ' ' + ip);
		}
	}

	if (ip_count == 0) {
		echolog('# ERROR, No IP provided');
		return 1;
	}

	/* remove leftover round-robin records when the IP count was reduced */
	for (let i = ip_count; i < length(ids); i++) {
		let result = cf_request(auth, 'DELETE', '/zones/' + zone_id + '/dns_records/' + ids[i], null, null);

		if (has_error(result))
			log_response_error('DELETE record ' + ids[i], result);
		else
			echolog('DELETE record ' + ids[i]);
	}

	return failed ? 1 : 0;
}

exit(main(ARGV));
