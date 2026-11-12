#!/usr/bin/env python3
"""Independent PS3.18 chapter 11 witness: requests + websockets 17.1, synthetic data only."""
import asyncio
import json
import sys
import requests
import websockets
from websockets.asyncio.client import connect

BASE = sys.argv[1].rstrip('/')
HEADERS = {'Content-Type': 'application/dicom+json', 'Accept': 'application/dicom+json'}
UID = '2.25.2352001'
TX = '2.25.2352002'
GLOBAL = '1.2.840.10008.5.1.4.34.5'
FILTERED = GLOBAL + '.1'
statuses = {}


def attr(vr, value=None):
    return {'vr': vr, **({} if value is None else {'Value': [value]})}


def fixture():
    data = {'00741000': attr('CS', 'SCHEDULED'), '00741200': attr('CS', 'MEDIUM'),
            '00741204': attr('LO', 'PYTHON SYNTHETIC'), '00404005': attr('DT', '20260911090000'),
            '00404041': attr('CS', 'READY'), '00741002': attr('SQ'), '00741216': attr('SQ')}
    # CC.2.5.1.3 N-CREATE Type 2 elements: present, zero length permitted.
    for tag, vr in {'00081195': 'UI', '00741202': 'LO', '00741210': 'SQ', '00404025': 'SQ',
                    '00404026': 'SQ', '00404027': 'SQ', '00404018': 'SQ', '00400400': 'LT',
                    '00404021': 'SQ', '00100010': 'PN', '00100021': 'LO', '00100024': 'SQ',
                    '00101002': 'SQ', '00100030': 'DA', '00100040': 'CS', '00380010': 'LO',
                    '00380014': 'SQ', '00081080': 'LO', '00081084': 'SQ', '0040A370': 'SQ'}.items():
        data[tag] = attr(vr)
    return data


def call(name, method, path, expected, data=None, **kwargs):
    response = requests.request(method, BASE + path, headers=HEADERS,
                                json=None if data is None else [data], timeout=10, **kwargs)
    assert response.status_code == expected, (name, response.status_code, response.text)
    statuses[name] = response.status_code
    return response


def state(value):
    return {'00081195': attr('UI', TX), '00741000': attr('CS', value)}


def final_attributes():
    code = {'00080100': attr('SH', 'TEST'), '00080102': attr('SH', '99TEST'), '00080104': attr('LO', 'Synthetic')}
    return {'00741216': attr('SQ', {'00404028': attr('SQ', code),
                                   '00404050': attr('DT', '20260911090000'),
                                   '00404051': attr('DT', '20260911100000'),
                                   '00404019': attr('SQ', code), '00404033': attr('SQ')})}


async def event(ws):
    text = await asyncio.wait_for(ws.recv(), timeout=10)
    assert isinstance(text, str), 'Event must use opcode 1'
    obj = json.loads(text)
    assert isinstance(obj, dict), 'One DICOM JSON object per frame'
    assert obj['00000002'] == attr('UI', '1.2.840.10008.5.1.4.34.6.4')
    assert obj['00000110']['vr'] == 'US'
    assert obj['00001000']['vr'] == 'UI'
    assert obj['00001002']['vr'] == 'US'
    assert '00081195' not in obj
    return obj


def socket(url):
    return connect(url, subprotocols=['dicom'], origin=BASE,
                   additional_headers={'Content-Type': 'application/dicom+json'},
                   compression=None, open_timeout=10, close_timeout=3)


async def main():
    assert websockets.__version__ == '17.1', websockets.__version__
    created = call('create', 'POST', '/workitems?workitem=' + UID, 201, fixture())
    assert created.headers['Location'] == BASE + '/workitems/' + UID
    assert created.headers['Warning'] == '299 ' + BASE + ': The Workitem was created with modifications.'
    call('duplicate', 'POST', '/workitems?workitem=' + UID, 409, fixture())
    retrieved = call('retrieve', 'GET', '/workitems/' + UID, 200)
    assert '00081195' not in retrieved.json()[0]
    call('update_scheduled', 'POST', '/workitems/' + UID, 200, {'00741204': attr('LO', 'UPDATED')})
    found = call('search', 'GET', '/workitems?ProcedureStepState=SCHEDULED&fuzzymatching=true', 200)
    assert len(found.json()) == 1 and 'fuzzymatching' in found.headers['Warning']
    call('empty_search', 'GET', '/workitems?ProcedureStepState=COMPLETED', 200)
    subscription = call('subscribe_disconnected', 'POST', '/workitems/' + UID + '/subscribers/PYTHON?deletionlock=true', 201)
    url = subscription.headers['Content-Location']
    assert url == BASE.replace('http:', 'ws:').replace('https:', 'wss:') + '/subscribers/PYTHON'
    sequence = []
    async with socket(url) as ws:
        assert ws.response.status_code == 101 and ws.subprotocol == 'dicom'
        assert 'Transfer-Encoding' not in ws.response.headers
        assert ws.response.headers['Upgrade'].lower() == 'websocket'
        call('subscribe_initial', 'POST', '/workitems/' + UID + '/subscribers/PYTHON?deletionlock=true', 201)
        sequence.append((await event(ws))['00741000']['Value'][0])
        call('claim', 'PUT', '/workitems/' + UID + '/state?requester=PYTHON', 200, state('IN PROGRESS'))
        sequence.append((await event(ws))['00741000']['Value'][0])
        call('progress', 'POST', '/workitems/' + UID + '?transaction-uid=' + TX, 200,
             {'00741002': attr('SQ', {'00741004': attr('DS', '50')})})
        progress = await event(ws)
        assert progress['00001002']['Value'] == [3]
        sequence.append('progress')
        pong = await ws.ping(b'independent-ping')
        await asyncio.wait_for(pong, 5)
        call('final_attributes', 'POST', '/workitems/' + UID + '?transaction-uid=' + TX, 200, final_attributes())
        call('complete', 'PUT', '/workitems/' + UID + '/state', 200, state('COMPLETED'))
        sequence.append((await event(ws))['00741000']['Value'][0])
        repeated = call('repeat_complete', 'PUT', '/workitems/' + UID + '/state', 200, state('COMPLETED'))
        assert repeated.headers['Warning'].endswith('The UPS is already in the requested state of COMPLETED.')
    assert sequence == ['SCHEDULED', 'IN PROGRESS', 'progress', 'COMPLETED'], sequence
    call('unsubscribe', 'DELETE', '/workitems/' + UID + '/subscribers/PYTHON', 200)
    call('missing_subscription', 'DELETE', '/workitems/' + UID + '/subscribers/PYTHON', 404)
    second = UID + '1'
    call('create_gap', 'POST', '/workitems?workitem=' + second, 201, fixture())
    async with socket(url) as ws:
        call('subscribe_gap', 'POST', '/workitems/' + second + '/subscribers/PYTHON', 201)
        assert (await event(ws))['00741000']['Value'] == ['SCHEDULED']
    call('claim_disconnected', 'PUT', '/workitems/' + second + '/state', 200, state('IN PROGRESS'))
    async with socket(url) as ws:
        # No replay; a new Subscribe transaction supplies the fresh initial state.
        call('resubscribe_gap', 'POST', '/workitems/' + second + '/subscribers/PYTHON', 201)
        fresh = await event(ws)
        assert fresh['00741000']['Value'] == ['IN PROGRESS']
        call('cancelrequest', 'POST', '/workitems/' + second + '/cancelrequest?requester=PYTHON', 202,
             {'00741238': attr('LT', 'Synthetic cancellation witness')})
        assert (await event(ws))['00001002']['Value'] == [2]
    async with socket(url) as ws:
        await ws.send('ignored client data')
        pong = await ws.ping(b'after-client-data')
        await asyncio.wait_for(pong, 5)
        try:
            # The server may close 1009 while the oversize frame is still being written.
            await ws.send('x' * (1024 * 1024 + 1))
        except websockets.exceptions.ConnectionClosed:
            pass
        await asyncio.wait_for(ws.wait_closed(), 5)
        assert ws.close_code == 1009, ws.close_code
    for uid in [GLOBAL, FILTERED]:
        suffix = '?filter=ProcedureStepState=IN%20PROGRESS' if uid == FILTERED else ''
        path = '/workitems/' + uid + '/subscribers/GLOBAL'
        call('subscribe_' + uid, 'POST', path + suffix, 201)
        call('suspend_' + uid, 'POST', path + '/suspend', 200)
        call('resubscribe_' + uid, 'POST', path + suffix, 201)
        call('unsubscribe_' + uid, 'DELETE', path, 200)
    print(json.dumps({'statuses': statuses, 'events': sequence, 'gap': True,
                      'fresh_state': fresh['00741000']['Value'][0],
                      'requests': requests.__version__, 'websockets': websockets.__version__}))


if __name__ == '__main__':
    asyncio.run(main())
