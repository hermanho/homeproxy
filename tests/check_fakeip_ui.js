#!/usr/bin/env node
'use strict';

// Run with the target router's luci-static/resources/validation.js as argv[2].
// Exercises the actual LuCI validator pipeline, without a browser or live UCI changes.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(path.join(__dirname,
    '../htdocs/luci-static/resources/view/homeproxy/client.js'), 'utf8');
const start = source.indexOf("so = ss.option(form.Value, 'fakeip_range'");
const end = source.indexOf("so = ss.option(form.Value, 'client_subnet'", start);
const fieldDefinition = source.slice(start, end);
const datatype = fieldDefinition.match(/so\.datatype = '([^']+)'/)[1];
const callbackSource = fieldDefinition.match(/so\.validate = (function\(section_id, value\) \{[\s\S]*?\n\t\t\});/)[1];
const translate = value => value;
const callback = new Function('_', `return (${callbackSource});`)(translate).bind({}, 'dns');

function extend(prototype) {
    function Constructor(...args) {
        if (this.__init__)
            this.__init__(...args);
    }
    Constructor.prototype = prototype;
    Constructor.extend = extend;
    return Constructor;
}

// Minimal DOM and baseclass adapters; validation logic comes from LuCI itself.
global.CustomEvent = class CustomEvent {
    constructor(type, options) { this.type = type; Object.assign(this, options); }
};
if (!String.prototype.format) {
    String.prototype.format = function(...args) {
        let index = 0;
        return this.replace(/%s/g, () => String(args[index++]));
    };
}
const luciSource = fs.readFileSync(process.argv[2], 'utf8');
const Factory = new Function('baseclass', 'findParent', '_', luciSource)(
    { extend }, () => true, translate);
const factory = new Factory();

function validate(value, type = datatype, fn = callback) {
    const field = {
        value,
        classList: { add() {}, remove() {} },
        setAttribute() {}, removeAttribute() {}, dispatchEvent() {}
    };
    return factory.create(field, type, false, fn).validate();
}

// Reproduce the reported bug: cidr4 passes only "15" to a custom callback.
let received;
assert.equal(validate('198.18.0.0/15', 'cidr4', value => {
    received = value;
    return callback(value);
}), false);
assert.equal(received, '15');

for (const value of ['198.18.0.0/15', '198.18.0.0/16', '198.19.0.0/16',
                     '198.18.2.0/24', '198.19.255.252/30'])
    assert.equal(validate(value), true, value);
for (const value of ['', '15', '198.19.0.0/15', '198.18.0.1/15',
                     '198.18.256.0/24', '198.20.0.0/16', '192.168.0.0/16',
                     '198.18.0.0/14', '198.18.0.0/31', '198.18.0.0'])
    assert.equal(validate(value), false, value);

console.log('PASS: reproduced LuCI CIDR callback mutation; valid Fake-IP networks accepted and invalid inputs rejected.');

// Modal Save must use current matcher values, including a newly added suffix.
const ruleStart = source.indexOf('/* Fake-IP rules use');
const ruleEnd = source.indexOf('/* Custom routing settings end */', ruleStart);
const rules = source.slice(ruleStart, ruleEnd);
assert.ok(!rules.includes("'source_ip_cidr'"));
const enable = rules.slice(rules.indexOf("so = ss.option(form.Flag, 'enabled'"),
    rules.indexOf("so = ss.option(form.DynamicList, 'domain'"));
assert.ok(!enable.includes('so.validate'), 'Enable must not retain stale cross-field validation');
const saveSource = rules.match(/ss\.handleModalSave = (function\(modalMap, ev\) \{[\s\S]*?\n\t\t\});/)[1];
let notifications = 0;
let saves = 0;
const save = new Function('ui', 'E', '_', `return (${saveSource});`)(
    { addNotification() { notifications++; } }, (_, attrs, text) => text, translate);
const event = {};
const section = { super(method, args) {
    assert.equal(method, 'handleModalSave');
    assert.equal(args[1], event);
    saves++;
    return Promise.resolve();
} };
const values = { enabled: '1' };
const modalMap = { section: 'fake_ip_tvb', lookupOption(name, id) {
    assert.equal(id, 'fake_ip_tvb');
    return [{ formvalue() { return values[name]; } }];
} };
save.call(section, modalMap, event);
assert.equal(notifications, 1);
assert.equal(saves, 0);
values.domain_suffix = ['akamai.tvb.com'];
save.call(section, modalMap, event);
assert.equal(saves, 1, 'Suffix-only rule without source IP must save');
for (const matcher of ['domain', 'domain_suffix', 'domain_regex', 'rule_set']) {
    delete values.domain_suffix;
    values[matcher] = ['example'];
    save.call(section, modalMap, event);
    delete values[matcher];
}
assert.equal(saves, 5);
values.domain_suffix = ['  '];
save.call(section, modalMap, event);
assert.equal(saves, 5);
assert.equal(notifications, 2);
values.enabled = '0';
save.call(section, modalMap, event);
assert.equal(saves, 6, 'Disabled empty rules remain editable');
console.log('PASS: source field removed; modal Save accepts current domain/suffix/regex/ruleset and warns on missing matchers.');
