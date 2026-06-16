'use strict';
'require view';
'require ui';
'require uci';
'require fs';
'require rpc';

var callServiceList = rpc.declare({
    object: 'service',
    method: 'list',
    params: ['name'],
    expect: { '': {} }
});

function toList(value) {
    if (Array.isArray(value))
        return value.filter(function(v) { return typeof v === 'string' && v.length > 0; });

    if (typeof value === 'string' && value.length > 0)
        return value.split(',').map(function(v) { return v.trim(); }).filter(function(v) { return v.length > 0; });

    return [];
}

function toComma(value) {
    return toList(value).join(',');
}

function calculatePeerId(publicKey) {
    var constants = [];
    var hash = [];
    var primeCounter = 0;
    var candidate = 2;

    function isPrime(value) {
        var divisor;

        for (divisor = 2; divisor * divisor <= value; divisor++)
            if (value % divisor === 0)
                return false;

        return true;
    }

    while (primeCounter < 64) {
        if (isPrime(candidate)) {
            if (primeCounter < 8)
                hash[primeCounter] = (Math.pow(candidate, 0.5) * 0x100000000) | 0;

            constants[primeCounter] = (Math.pow(candidate, 1 / 3) * 0x100000000) | 0;
            primeCounter++;
        }

        candidate++;
    }

    var bytes = [];
    var i;

    for (i = 0; i < publicKey.length; i++)
        bytes.push(publicKey.charCodeAt(i));

    var bitLength = bytes.length * 8;
    bytes.push(0x80);

    while (bytes.length % 64 !== 56)
        bytes.push(0);

    for (i = 7; i >= 0; i--)
        bytes.push(i < 4 ? (bitLength >>> (i * 8)) & 0xff : 0);

    function rotateRight(value, shift) {
        return (value >>> shift) | (value << (32 - shift));
    }

    for (var offset = 0; offset < bytes.length; offset += 64) {
        var words = [];

        for (i = 0; i < 16; i++) {
            var wordOffset = offset + i * 4;
            words[i] = (bytes[wordOffset] << 24) |
                (bytes[wordOffset + 1] << 16) |
                (bytes[wordOffset + 2] << 8) |
                bytes[wordOffset + 3];
        }

        for (i = 16; i < 64; i++) {
            var s0 = rotateRight(words[i - 15], 7) ^ rotateRight(words[i - 15], 18) ^ (words[i - 15] >>> 3);
            var s1 = rotateRight(words[i - 2], 17) ^ rotateRight(words[i - 2], 19) ^ (words[i - 2] >>> 10);
            words[i] = (words[i - 16] + s0 + words[i - 7] + s1) | 0;
        }

        var a = hash[0];
        var b = hash[1];
        var c = hash[2];
        var d = hash[3];
        var e = hash[4];
        var f = hash[5];
        var g = hash[6];
        var h = hash[7];

        for (i = 0; i < 64; i++) {
            var sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
            var choice = (e & f) ^ (~e & g);
            var temp1 = (h + sum1 + choice + constants[i] + words[i]) | 0;
            var sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
            var majority = (a & b) ^ (a & c) ^ (b & c);
            var temp2 = (sum0 + majority) | 0;

            h = g;
            g = f;
            f = e;
            e = (d + temp1) | 0;
            d = c;
            c = b;
            b = a;
            a = (temp1 + temp2) | 0;
        }

        hash[0] = (hash[0] + a) | 0;
        hash[1] = (hash[1] + b) | 0;
        hash[2] = (hash[2] + c) | 0;
        hash[3] = (hash[3] + d) | 0;
        hash[4] = (hash[4] + e) | 0;
        hash[5] = (hash[5] + f) | 0;
        hash[6] = (hash[6] + g) | 0;
        hash[7] = (hash[7] + h) | 0;
    }

    var digest = [];

    for (i = 0; i < 4; i++) {
        digest.push((hash[i] >>> 24) & 0xff);
        digest.push((hash[i] >>> 16) & 0xff);
        digest.push((hash[i] >>> 8) & 0xff);
        digest.push(hash[i] & 0xff);
    }

    var alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
    var peerId = '';
    var buffer = 0;
    var bits = 0;

    digest.forEach(function(byte) {
        buffer = (buffer << 8) | byte;
        bits += 8;

        while (bits >= 5) {
            peerId += alphabet[(buffer >>> (bits - 5)) & 31];
            bits -= 5;
        }
    });

    if (bits > 0)
        peerId += alphabet[(buffer << (5 - bits)) & 31];

    return peerId;
}

return view.extend({
    policyState: {},
    cacheState: {},
    interfaceAddresses: {},

    load: function() {
        var self = this;

        return uci.load('wpcp-agent').then(function() {
            var instances = uci.sections('wpcp-agent', 'instance').map(function(section) {
                return {
                    sid: section['.name'],
                    name: section['.name'],
                    enabled: String(section.enabled != null ? section.enabled : '1'),
                    interface: section.interface || 'wg0',
                    broker: section.broker || '',
                    port: section.port || '1883',
                    username: section.username || '',
                    tls: String(section.tls != null ? section.tls : '0'),
                    topic_prefix: section.topic_prefix || 'wg',
                    config: section.config || '',
                    auto: String(section.auto != null ? section.auto : '0'),
                    log_level: section.log_level || 'info',
                    cache_file: section.cache_file || ''
                };
            });

            self.instances = instances;

            return Promise.all([
                self.loadPolicies(instances),
                self.loadCaches(instances),
                self.loadInterfaceAddresses(instances),
                self.loadServiceStatus()
            ]);
        });
    },

    loadPolicies: function(instances) {
        var self = this;
        var reads = [];

        instances.forEach(function(instance) {
            var path = instance.config;
            if (!path)
                return;

            reads.push(L.resolveDefault(fs.read(path), null).then(function(content) {
                if (!content) {
                    self.policyState[path] = { error: _('Config file not found or unreadable'), data: null };
                    return;
                }

                try {
                    self.policyState[path] = { error: null, data: JSON.parse(content) };
                }
                catch (e) {
                    self.policyState[path] = { error: _('Invalid JSON: %s').format(e.message), data: null };
                }
            }));
        });

        return Promise.all(reads);
    },

    loadCaches: function(instances) {
        var self = this;
        var reads = [];

        instances.forEach(function(instance) {
            var path = self.getCacheFile(instance);
            if (!path || self.cacheState[path])
                return;

            reads.push(L.resolveDefault(fs.read(path), null).then(function(content) {
                if (!content) {
                    self.cacheState[path] = { error: null, data: null };
                    return;
                }

                try {
                    self.cacheState[path] = { error: null, data: JSON.parse(content) };
                }
                catch (e) {
                    self.cacheState[path] = { error: null, data: null };
                }
            }));
        });

        return Promise.all(reads);
    },

    loadServiceStatus: function() {
        return L.resolveDefault(callServiceList('wpcp-agent'), {}).then(function(res) {
            return res || {};
        });
    },

    loadInterfaceAddresses: function(instances) {
        var self = this;
        var reads = [];

        instances.forEach(function(instance) {
            reads.push(self.loadDeviceAddresses(instance));
        });

        return Promise.all(reads);
    },

    loadDeviceAddresses: function(instance) {
        var self = this;

        return L.resolveDefault(fs.exec('/sbin/ip', ['-o', 'addr', 'show', 'dev', instance.interface]), null)
            .then(function(res) {
                var addresses = [];

                if (res && res.stdout) {
                    res.stdout.split(/\n/).forEach(function(line) {
                        var m = line.match(/^\d+:\s+\S+\s+inet6?\s+(\S+)/);

                        if (m && m[1])
                            addresses.push(m[1]);
                    });
                }

                self.interfaceAddresses[instance.interface] = addresses;
            });
    },

    getCacheFile: function(instance) {
        if (instance.cache_file)
            return instance.cache_file;

        return '/tmp/wpcp-%s-cache.json'.format(instance.interface || 'wg0');
    },

    getPeerState: function(instance, peerId) {
        var st = this.cacheState[this.getCacheFile(instance)];
        var peer;

        if (!st || !st.data || !st.data.peers)
            return 'N/A';

        peer = st.data.peers[peerId];
        if (!peer || !peer.state)
            return 'N/A';

        return peer.state;
    },

    renderPeerState: function(instance, peerId) {
        var state = this.getPeerState(instance, peerId);

        if (state === 'CONNECTED')
            return E('span', { 'class': 'label success' }, state);

        return E('span', { 'class': 'label' }, state);
    },

    getInterfacePeerId: function(interfacePolicy) {
        if (!interfacePolicy || !interfacePolicy.peer_id)
            return '';

        return interfacePolicy.peer_id;
    },

    getInterfaceEndpoint: function(instance, peerId, family) {
        var st = this.cacheState[this.getCacheFile(instance)];
        var peer;
        var endpoint;

        if (!peerId || !st || !st.data || !st.data.peers)
            return '';

        peer = st.data.peers[peerId];
        endpoint = peer && peer.endpoint && peer.endpoint[family];

        if (!endpoint || !endpoint.endpoint)
            return '';

        return endpoint.endpoint;
    },

    renderEndpointItem: function(label, endpoint) {
        return E('span', {
            'class': endpoint ? 'label success' : 'label',
            'style': 'margin-right: .35em'
        }, endpoint || label);
    },

    renderInterfaceEndpoint: function(instance, interfacePolicy) {
        var peerId = this.getInterfacePeerId(interfacePolicy);
        var ipv4 = this.getInterfaceEndpoint(instance, peerId, 'ipv4');
        var ipv6 = this.getInterfaceEndpoint(instance, peerId, 'ipv6');

        return E('div', {}, [
            _('Interface endpoint: '),
            this.renderEndpointItem('IPv4', ipv4),
            this.renderEndpointItem('IPv6', ipv6)
        ]);
    },

    getRuntimeInterfaceAddresses: function(instance) {
        var addresses = [];

        (this.interfaceAddresses[instance.interface] || []).forEach(function(addr) {
            if (addresses.indexOf(addr) === -1)
                addresses.push(addr);
        });

        return addresses.join(',');
    },

    renderInterfaceAddresses: function(instance) {
        var addresses = this.getRuntimeInterfaceAddresses(instance);

        if (!addresses)
            return E('div', {}, [
                _('Interface address: '),
                E('span', { 'class': 'label' }, _('None'))
            ]);

        return E('div', {}, [
            _('Interface address: '),
            E('span', { 'class': 'label notice' }, addresses)
        ]);
    },

    runInstanceAction: function(instance, action) {
        return fs.exec('/etc/init.d/wpcp-agent', [action, instance.sid]).then(function() {
            var refreshDelay = action === 'stop' ? 3000 : 1000;

            ui.addNotification(null, E('p', _('Instance "%s" action "%s" executed.').format(instance.name, action)));
            window.setTimeout(function() {
                window.location.reload();
            }, refreshDelay);
        }).catch(function(err) {
            ui.addNotification(null, E('p', _('Instance "%s" action "%s" failed: %s').format(instance.name, action, err.message || err)), 'error');
        });
    },

    setInstanceEnabled: function(instance, enabled) {
        uci.set('wpcp-agent', instance.sid, 'enabled', enabled ? '1' : '0');

        return uci.save()
            .then(function() { return rpc.call('uci', 'commit', { config: 'wpcp-agent' }); })
            .then(function() { uci.unload('wpcp-agent'); })
            .then(function() { return uci.load('wpcp-agent'); })
            .then(function() {
                ui.addNotification(null, E('p', _('Instance "%s" updated.').format(instance.name)));
                window.location.reload();
            })
            .catch(function(err) {
                ui.addNotification(null, E('p', _('Failed to update instance: %s').format(err.message || err)), 'error');
            });
    },

    getPeerMap: function(instance) {
        var path = instance.config;
        var iface = instance.interface;
        var st = this.policyState[path];

        if (!path || !st || !st.data)
            return null;

        if (!st.data[iface])
            st.data[iface] = {};

        if (!st.data[iface].peers || typeof st.data[iface].peers !== 'object')
            st.data[iface].peers = {};

        return st.data[iface].peers;
    },

    writePolicy: function(path, notificationTimeout) {
        var self = this;
        var st = self.policyState[path];

        if (!st || !st.data)
            return Promise.reject(new Error(_('No parsed policy loaded for %s').format(path)));

        var body = JSON.stringify(st.data, null, 2) + '\n';

        return fs.write(path, body)
            .then(function() {
                var notification = ui.addNotification(null, E('p', _('Policy saved: %s').format(path)));

                if (notificationTimeout > 0) {
                    window.setTimeout(function() {
                        if (notification.parentNode)
                            notification.parentNode.removeChild(notification);
                    }, notificationTimeout);
                }
            });
    },

    saveNewPeer: function(instance, fields, errorNode, addButton) {
        var publicKey = fields.publicKey.value.trim();
        var allowedIps = fields.allowedIps.value;
        var assignedIps = fields.assignedIps.value;
        var description = fields.description.value.trim();

        errorNode.textContent = '';
        errorNode.style.display = 'none';

        if (!description) {
            errorNode.textContent = _('Description is required and is used as the peer name.');
            errorNode.style.display = '';
            fields.description.focus();
            return;
        }

        if (!/^[A-Za-z0-9+/]{43}=$/.test(publicKey)) {
            errorNode.textContent = _('Invalid WireGuard public key. Expected a 44-character Base64 key.');
            errorNode.style.display = '';
            fields.publicKey.focus();
            return;
        }

        var peerId = calculatePeerId(publicKey);

        var peers = this.getPeerMap(instance);
        if (!peers) {
            errorNode.textContent = _('Cannot add peer: missing or invalid JSON config for this instance.');
            errorNode.style.display = '';
            return;
        }

        if (peers[peerId]) {
            errorNode.textContent = _('Peer already exists: %s').format(peerId);
            errorNode.style.display = '';
            fields.publicKey.focus();
            return;
        }

        addButton.disabled = true;

        peers[peerId] = {
            public_key: publicKey,
            allowed_ips: toList(allowedIps),
            assigned_ips: toList(assignedIps),
            description: description,
            disabled: '0'
        };

        this.writePolicy(instance.config)
            .then(function() {
                ui.hideModal();
                window.location.reload();
            })
            .catch(function(err) {
                delete peers[peerId];
                addButton.disabled = false;
                errorNode.textContent = _('Failed to save new peer: %s').format(err.message || err);
                errorNode.style.display = '';
            });
    },

    addPeer: function(instance) {
        var self = this;
        var fields = {
            description: E('input', {
                'class': 'cbi-input-text',
                'type': 'text',
                'required': 'required',
                'autocomplete': 'off',
                'placeholder': _('Peer name')
            }),
            publicKey: E('input', {
                'class': 'cbi-input-text',
                'type': 'text',
                'required': 'required',
                'autocomplete': 'off',
                'placeholder': _('44-character WireGuard public key')
            }),
            allowedIps: E('input', {
                'class': 'cbi-input-text',
                'type': 'text',
                'autocomplete': 'off',
                'placeholder': _('For example: 10.0.0.2/32, fd00::2/128')
            }),
            assignedIps: E('input', {
                'class': 'cbi-input-text',
                'type': 'text',
                'autocomplete': 'off',
                'placeholder': _('For example: 10.0.0.1/24')
            })
        };
        var errorNode = E('div', {
            'class': 'alert-message error',
            'style': 'display: none; margin-bottom: 1em'
        });
        var addButton = E('button', {
            'class': 'btn cbi-button cbi-button-positive important',
            'type': 'submit'
        }, _('Add'));
        var form = E('form', {
            'submit': function(ev) {
                ev.preventDefault();
                self.saveNewPeer(instance, fields, errorNode, addButton);
            }
        }, [
            errorNode,
            E('div', { 'class': 'cbi-value' }, [
                E('label', {
                    'class': 'cbi-value-title',
                    'for': 'wpcp-add-description'
                }, _('Description')),
                E('div', { 'class': 'cbi-value-field' }, [
                    fields.description,
                    E('div', { 'class': 'cbi-value-description' },
                        _('Required peer name shown in the policy table and delete confirmation.'))
                ])
            ]),
            E('div', { 'class': 'cbi-value' }, [
                E('label', {
                    'class': 'cbi-value-title',
                    'for': 'wpcp-add-public-key'
                }, _('Public key')),
                E('div', { 'class': 'cbi-value-field' }, [
                    fields.publicKey,
                    E('div', { 'class': 'cbi-value-description' },
                        _('Peer ID is calculated automatically from this public key.'))
                ])
            ]),
            E('div', { 'class': 'cbi-value' }, [
                E('label', {
                    'class': 'cbi-value-title',
                    'for': 'wpcp-add-allowed-ips'
                }, _('Allowed IPs')),
                E('div', { 'class': 'cbi-value-field' }, [
                    fields.allowedIps,
                    E('div', { 'class': 'cbi-value-description' },
                        _('Comma-separated IP addresses or CIDR networks.'))
                ])
            ]),
            E('div', { 'class': 'cbi-value' }, [
                E('label', {
                    'class': 'cbi-value-title',
                    'for': 'wpcp-add-assigned-ips'
                }, _('Assigned IPs')),
                E('div', { 'class': 'cbi-value-field' }, [
                    fields.assignedIps,
                    E('div', { 'class': 'cbi-value-description' },
                        _('Comma-separated interface addresses assigned for this peer.'))
                ])
            ]),
            E('div', { 'class': 'right' }, [
                E('button', {
                    'class': 'btn',
                    'type': 'button',
                    'click': ui.hideModal
                }, _('Cancel')),
                ' ',
                addButton
            ])
        ]);

        fields.publicKey.id = 'wpcp-add-public-key';
        fields.allowedIps.id = 'wpcp-add-allowed-ips';
        fields.assignedIps.id = 'wpcp-add-assigned-ips';
        fields.description.id = 'wpcp-add-description';

        ui.showModal(_('Add Peer to %s').format(instance.interface), [form]);
        fields.description.focus();
    },

    editPeer: function(instance, peerId) {
        var peers = this.getPeerMap(instance);
        if (!peers || !peers[peerId])
            return;

        var p = peers[peerId];
        var self = this;
        var fields = {
            description: E('input', {
                'class': 'cbi-input-text',
                'type': 'text',
                'required': 'required',
                'autocomplete': 'off',
                'placeholder': _('Peer name'),
                'value': p.description || ''
            }),
            publicKey: E('input', {
                'class': 'cbi-input-text',
                'type': 'text',
                'disabled': 'disabled',
                'value': p.public_key || ''
            }),
            allowedIps: E('input', {
                'class': 'cbi-input-text',
                'type': 'text',
                'autocomplete': 'off',
                'placeholder': _('For example: 10.0.0.2/32, fd00::2/128'),
                'value': toComma(p.allowed_ips)
            }),
            assignedIps: E('input', {
                'class': 'cbi-input-text',
                'type': 'text',
                'autocomplete': 'off',
                'placeholder': _('For example: 10.0.0.1/24'),
                'value': toComma(p.assigned_ips)
            })
        };
        var errorNode = E('div', {
            'class': 'alert-message error',
            'style': 'display: none; margin-bottom: 1em'
        });
        var saveButton = E('button', {
            'class': 'btn cbi-button cbi-button-positive important',
            'type': 'submit'
        }, _('Save'));
        var form = E('form', {
            'submit': function(ev) {
                ev.preventDefault();
                self.savePeerEdit(instance, peerId, fields, errorNode, saveButton);
            }
        }, [
            errorNode,
            E('div', { 'class': 'cbi-value' }, [
                E('label', {
                    'class': 'cbi-value-title',
                    'for': 'wpcp-edit-description'
                }, _('Description')),
                E('div', { 'class': 'cbi-value-field' }, [
                    fields.description,
                    E('div', { 'class': 'cbi-value-description' },
                        _('Required peer name shown in the policy table and delete confirmation.'))
                ])
            ]),
            E('div', { 'class': 'cbi-value' }, [
                E('label', {
                    'class': 'cbi-value-title',
                    'for': 'wpcp-edit-public-key'
                }, _('Public key')),
                E('div', { 'class': 'cbi-value-field' }, [
                    fields.publicKey,
                    E('div', { 'class': 'cbi-value-description' },
                        _('Public key cannot be changed because it determines the Peer ID.'))
                ])
            ]),
            E('div', { 'class': 'cbi-value' }, [
                E('label', {
                    'class': 'cbi-value-title',
                    'for': 'wpcp-edit-allowed-ips'
                }, _('Allowed IPs')),
                E('div', { 'class': 'cbi-value-field' }, [
                    fields.allowedIps,
                    E('div', { 'class': 'cbi-value-description' },
                        _('Comma-separated IP addresses or CIDR networks.'))
                ])
            ]),
            E('div', { 'class': 'cbi-value' }, [
                E('label', {
                    'class': 'cbi-value-title',
                    'for': 'wpcp-edit-assigned-ips'
                }, _('Assigned IPs')),
                E('div', { 'class': 'cbi-value-field' }, [
                    fields.assignedIps,
                    E('div', { 'class': 'cbi-value-description' },
                        _('Comma-separated interface addresses assigned for this peer.'))
                ])
            ]),
            E('div', { 'class': 'right' }, [
                E('button', {
                    'class': 'btn',
                    'type': 'button',
                    'click': ui.hideModal
                }, _('Cancel')),
                ' ',
                saveButton
            ])
        ]);

        fields.description.id = 'wpcp-edit-description';
        fields.publicKey.id = 'wpcp-edit-public-key';
        fields.allowedIps.id = 'wpcp-edit-allowed-ips';
        fields.assignedIps.id = 'wpcp-edit-assigned-ips';

        ui.showModal(_('Edit Peer "%s"').format(p.description || peerId), [form]);
        fields.description.focus();
    },

    savePeerEdit: function(instance, peerId, fields, errorNode, saveButton) {
        var peers = this.getPeerMap(instance);
        if (!peers || !peers[peerId])
            return;

        var p = peers[peerId];
        var description = fields.description.value.trim();

        errorNode.textContent = '';
        errorNode.style.display = 'none';

        if (!description) {
            errorNode.textContent = _('Description is required and is used as the peer name.');
            errorNode.style.display = '';
            fields.description.focus();
            return;
        }

        var previous = {
            allowed_ips: p.allowed_ips,
            assigned_ips: p.assigned_ips,
            description: p.description
        };

        p.allowed_ips = toList(fields.allowedIps.value);
        p.assigned_ips = toList(fields.assignedIps.value);
        p.description = description;
        saveButton.disabled = true;

        this.writePolicy(instance.config)
            .then(function() {
                ui.hideModal();
                window.location.reload();
            })
            .catch(function(err) {
                p.allowed_ips = previous.allowed_ips;
                p.assigned_ips = previous.assigned_ips;
                p.description = previous.description;
                saveButton.disabled = false;
                errorNode.textContent = _('Failed to save peer edit: %s').format(err.message || err);
                errorNode.style.display = '';
            });
    },

    setPeerDisabled: function(instance, peerId, disabled) {
        var peers = this.getPeerMap(instance);
        if (!peers || !peers[peerId])
            return;

        peers[peerId].disabled = disabled ? '1' : '0';

        this.writePolicy(instance.config, 1000)
            .catch(function(err) {
                ui.addNotification(null, E('p', _('Failed to update peer flag: %s').format(err.message || err)), 'error');
            });
    },

    deletePeer: function(instance, peerId) {
        var peers = this.getPeerMap(instance);
        if (!peers || !peers[peerId])
            return;

        var peerName = peers[peerId].description || peerId;

        if (!confirm(_('Delete peer "%s" from policy file?').format(peerName)))
            return;

        delete peers[peerId];

        this.writePolicy(instance.config)
            .then(function() { window.location.reload(); })
            .catch(function(err) {
                ui.addNotification(null, E('p', _('Failed to delete peer: %s').format(err.message || err)), 'error');
            });
    },

    renderServiceStatus: function(instance, serviceData) {
        var running = false;

        var svc = serviceData['wpcp-agent'] || serviceData.wpcp_agent || null;

        if (svc && svc.instances && svc.instances[instance.sid]) {
            running = !!svc.instances[instance.sid].running;
        }

        return E('span', {
            'class': running ? 'label success' : 'label'
        }, running ? _('running') : _('stopped'));
    },

    renderPeersTable: function(instance) {
        var st = this.policyState[instance.config];
        if (!instance.config)
            return E('p', _('No JSON config file configured for this instance.'));

        if (!st)
            return E('p', _('Policy state not loaded.'));

        if (st.error)
            return E('p', { 'class': 'alert-message error' }, st.error);

        var peers = this.getPeerMap(instance);
        var rows = [];
        var self = this;
        var interfacePolicy = st.data[instance.interface] || {};

        Object.keys(peers).sort().forEach(function(peerId) {
            var p = peers[peerId] || {};
            var isDisabled = String(p.disabled != null ? p.disabled : '0') === '1';

            rows.push(E('tr', { 'class': 'tr cbi-section-table-row' }, [
                E('td', {
                    'class': 'td',
                    'data-title': _('Peer')
                }, p.description || ''),
                E('td', {
                    'class': 'td',
                    'data-title': _('State')
                }, self.renderPeerState(instance, peerId)),
                E('td', {
                    'class': 'td',
                    'data-title': _('Allowed IPs')
                }, toComma(p.allowed_ips)),
                E('td', {
                    'class': 'td',
                    'data-title': _('Assigned IPs')
                }, toComma(p.assigned_ips)),
                E('td', {
                    'class': 'td cbi-value-field',
                    'data-title': _('Enabled')
                }, [
                    E('input', {
                        'class': 'cbi-input-checkbox',
                        'type': 'checkbox',
                        'checked': isDisabled ? null : 'checked',
                        'change': function(ev) {
                            return self.setPeerDisabled(instance, peerId, !ev.target.checked);
                        }
                    })
                ]),
                E('td', {
                    'class': 'td cbi-section-actions',
                    'data-title': _('Actions')
                }, [
                    E('div', { 'class': 'wpcp-peer-actions' }, [
                        E('button', {
                            'class': 'btn cbi-button cbi-button-action',
                            'click': ui.createHandlerFn(self, 'editPeer', instance, peerId)
                        }, _('Edit')),
                        E('button', {
                            'class': 'btn cbi-button cbi-button-remove',
                            'click': ui.createHandlerFn(self, 'deletePeer', instance, peerId)
                        }, _('Delete'))
                    ])
                ])
            ]));
        });

        if (!rows.length)
            rows.push(E('tr', {}, [E('td', { 'colspan': 6 }, _('No peers found for this interface in policy JSON.'))]));

        return E('div', {}, [
            E('style', {}, [
                '.wpcp-peer-actions {',
                'display: inline-flex; flex-flow: row nowrap; align-items: center; gap: .35em;',
                '}',
                '.wpcp-peer-actions .btn {',
                'display: inline-block; width: auto; margin: 0; flex: 0 0 auto;',
                '}',
                '@media screen and (max-width: 600px) {',
                '.wpcp-peer-table, .wpcp-peer-table tbody { display: block; }',
                '.wpcp-peer-table .table-titles { display: none; }',
                '.wpcp-peer-table .cbi-section-table-row {',
                'display: block; margin: 0 0 1em; padding: .5em;',
                'border: 1px solid var(--border-color-medium, #ccc);',
                '}',
                '.wpcp-peer-table .cbi-section-table-row > .td {',
                'display: grid; grid-template-columns: minmax(7em, 35%) minmax(0, 1fr);',
                'align-items: center; width: auto; min-height: 2.4em;',
                'padding: .4em .25em; text-align: left;',
                '}',
                '.wpcp-peer-table .cbi-section-table-row > .td::before {',
                'content: attr(data-title); display: block; padding-right: .75em;',
                'font-weight: 600; overflow-wrap: anywhere;',
                '}',
                '.wpcp-peer-table .cbi-section-actions {',
                'display: grid; white-space: nowrap;',
                '}',
                '}'
            ].join('\n')),
            E('div', {
                'style': 'display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: .5em; margin: 1em 0'
            }, [
                E('div', {}, [
                    E('div', {}, _('Cache file: %s').format(this.getCacheFile(instance))),
                    E('div', {}, _('Policy file: %s').format(instance.config)),
                    this.renderInterfaceAddresses(instance),
                    this.renderInterfaceEndpoint(instance, interfacePolicy)
                ]),
                E('button', {
                    'class': 'btn cbi-button cbi-button-add',
                    'click': ui.createHandlerFn(this, 'addPeer', instance)
                }, _('Add Peer'))
            ]),
            E('table', { 'class': 'table cbi-section-table wpcp-peer-table' }, [
                E('tr', { 'class': 'tr table-titles' }, [
                    E('th', { 'class': 'th' }, _('Peer')),
                    E('th', { 'class': 'th' }, _('State')),
                    E('th', { 'class': 'th' }, _('Allowed IPs')),
                    E('th', { 'class': 'th' }, _('Assigned IPs')),
                    E('th', { 'class': 'th' }, _('Enabled')),
                    E('th', { 'class': 'th' }, _('Actions'))
                ])
            ].concat(rows)),
            E('p', { 'class': 'help-text' }, _('Checked peers are enabled for auto-management. Unchecked peers are skipped at config level and are not immediately deactivated at runtime.'))
        ]);
    },

    renderInstanceCard: function(instance, serviceData) {
        var isEnabled = instance.enabled === '1';

        return E('div', { 'class': 'cbi-section' }, [
            E('style', {}, [
                '.wpcp-service-row {',
                'display: grid; grid-template-columns: 14em auto minmax(10em, 1fr);',
                'align-items: center; column-gap: .75em; padding: .65em .5em;',
                'border-top: 1px solid var(--border-color-medium, #ccc);',
                'border-bottom: 1px solid var(--border-color-medium, #ccc);',
                '}',
                '.wpcp-service-label, .wpcp-service-state {',
                'min-width: 0; white-space: nowrap;',
                '}',
                '.wpcp-service-actions {',
                'display: inline-flex; flex-flow: row nowrap; justify-self: end; gap: .35em;',
                '}',
                '@media screen and (max-width: 600px) {',
                '.wpcp-service-row {',
                'grid-template-columns: auto auto minmax(0, 1fr); column-gap: .4em;',
                '}',
                '.wpcp-service-state { justify-self: start; }',
                '.wpcp-service-actions {',
                'justify-self: end; gap: .2em;',
                '}',
                '.wpcp-service-actions .btn {',
                'padding-left: .55em; padding-right: .55em;',
                '}',
                '}'
            ].join('\n')),
            E('h3', {}, _('Instance: %s').format(instance.name)),
            E('div', { 'class': 'wpcp-service-row' }, [
                E('div', { 'class': 'wpcp-service-label' }, _('Service status')),
                E('div', { 'class': 'wpcp-service-state' },
                    this.renderServiceStatus(instance, serviceData)),
                E('div', { 'class': 'wpcp-service-actions' }, [
                    E('button', {
                        'class': 'btn cbi-button cbi-button-apply',
                        'style': 'float: none',
                        'click': ui.createHandlerFn(this, 'runInstanceAction', instance, 'start')
                    }, _('Start')),
                    E('button', {
                        'class': 'btn cbi-button cbi-button-reset',
                        'style': 'float: none',
                        'click': ui.createHandlerFn(this, 'runInstanceAction', instance, 'stop')
                    }, _('Stop'))
                ])
            ]),
            E('div', {
                'class': 'cbi-page-actions',
                'style': 'display: flex; flex-flow: row wrap; gap: .5em; justify-content: flex-start; text-align: left'
            }, [
                E('button', {
                    'class': isEnabled ? 'btn cbi-button cbi-button-positive' : 'btn cbi-button cbi-button-negative',
                    'style': 'float: none; margin: 0',
                    'click': ui.createHandlerFn(this, 'setInstanceEnabled', instance, !isEnabled)
                }, isEnabled ? _('Enabled') : _('Disabled')),
                E('button', {
                    'class': 'btn cbi-button cbi-button-reload',
                    'style': 'float: none; margin: 0',
                    'click': ui.createHandlerFn(this, 'runInstanceAction', instance, 'restart')
                }, _('Restart')),
                E('button', {
                    'class': 'btn cbi-button cbi-button-action',
                    'style': 'float: none; margin: 0',
                    'click': ui.createHandlerFn(this, 'runInstanceAction', instance, 'reload')
                }, _('Reload')),
            ]),
            this.renderPeersTable(instance)
        ]);
    },

    render: function(data) {
        var serviceData = data[3] || {};
        var cards = [];

        cards.push(E('h2', {}, _('WPCP Agent')));
        cards.push(E('p', {}, _('Manage wpcp-agent instances and per-interface peer policy JSON files.')));

        if (!this.instances || !this.instances.length) {
            cards.push(E('div', { 'class': 'alert-message warning' }, _('No wpcp-agent instance section found in /etc/config/wpcp-agent')));
            return E('div', { 'class': 'cbi-map' }, cards);
        }

        this.instances.forEach(function(instance) {
            cards.push(this.renderInstanceCard(instance, serviceData));
        }, this);

        return E('div', { 'class': 'cbi-map' }, cards);
    },

    handleSaveApply: null,
    handleSave: null,
    handleReset: null
});
