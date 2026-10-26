"""Generate an import template and a private local receiver configuration. No credentials printed."""
import json
import os
from pathlib import Path
import secrets
import uuid

root = Path(__file__).resolve().parent
runtime = root / 'runtime-data'
runtime.mkdir(exist_ok=True, mode=0o700)
path_file = runtime / 'receiver-path.txt'
if path_file.exists():
    receiver_path = path_file.read_text().strip()
else:
    receiver_path = 'green-meter-' + secrets.token_urlsafe(24)
    path_file.write_text(receiver_path)
    path_file.chmod(0o600)

code = (root / 'normalize-summary.cjs').read_text().replace('module.exports = normalizeSummary;', '')
code += "\nreturn $input.all().map(item => ({ json: normalizeSummary(item.json.body) }));\n"
workflow = {
    'id': 'GreenMeterReceiver120', 'name': '绿电实验室 · 数据接收与负载初判',
    'active': False, 'versionId': str(uuid.uuid4()), 'settings': {'executionOrder': 'v1', 'saveExecutionProgress': False, 'saveDataSuccessExecution': 'all', 'executionTimeout': 15},
    'nodes': [
        {'id': 'meter-receiver', 'name': '接收本机采集摘要', 'type': 'n8n-nodes-base.webhook', 'typeVersion': 2, 'position': [260, 300], 'webhookId': str(uuid.uuid4()), 'parameters': {'httpMethod': 'POST', 'path': 'REPLACE_WITH_PRIVATE_PATH', 'responseMode': 'responseNode', 'options': {}}},
        {'id': 'meter-validate', 'name': '核对来源与标定', 'type': 'n8n-nodes-base.code', 'typeVersion': 2, 'position': [520, 300], 'parameters': {'mode': 'runOnceForAllItems', 'jsCode': code}},
        {'id': 'meter-response', 'name': '返回接收结果', 'type': 'n8n-nodes-base.respondToWebhook', 'typeVersion': 1.4, 'position': [780, 300], 'parameters': {'respondWith': 'json', 'responseBody': '={{ $json }}', 'options': {'responseCode': '={{ $json.ok ? 200 : 422 }}'}}}
    ],
    'connections': {'接收本机采集摘要': {'main': [[{'node': '核对来源与标定', 'type': 'main', 'index': 0}]]}, '核对来源与标定': {'main': [[{'node': '返回接收结果', 'type': 'main', 'index': 0}]]}}
}
(root / '绿电实验室-接收流程-模板.json').write_text(json.dumps(workflow, ensure_ascii=False, indent=2))
workflow['nodes'][0]['parameters']['path'] = receiver_path
private_workflow = runtime / '接收流程-本机私有.json'
private_workflow.write_text(json.dumps(workflow, ensure_ascii=False, indent=2)); private_workflow.chmod(0o600)
config = dict(transport='client', protocolName='socket128', host='192.168.1.2', bindIP='127.0.0.1', port=8266, registration=False, discovery=False, sampleRate=6400, lineHz=50, voltageScale=1.935205, currentScale=0.011848, voltageOffset=0, currentOffset=0, currentSign=1, points=128, headerHex='', trailerHex='', littleEndian=True, calibrated=False, stateOn=50, stateOff=10, holdOn=5, holdOff=20, webhook='http://127.0.0.1:5678/webhook/' + receiver_path, webhookEnabled=True, webhookInterval=5)
config_file = runtime / 'Mac本地n8n配置.json'
config_file.write_text(json.dumps(config, ensure_ascii=False, indent=2)); config_file.chmod(0o600)
print('Prepared workflow template and private local configuration. Receiver path is not printed.')
