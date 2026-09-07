"""Read-only repository audit; all HTTP mutations use a temporary database."""
import json, os, tempfile
from pathlib import Path
root = Path(tempfile.mkdtemp(prefix='gyrus-meta-probe-'))
os.environ['GYRUS_DATA_DIR'] = str(root)
os.environ['GYRUS_BRAIN_ROOT'] = str(root / 'brain')
os.environ['GYRUS_API_TOKEN'] = 'isolated-meta-probe'
from alembic import command
from alembic.config import Config
cfg = Config('alembic.ini')
command.upgrade(cfg, 'head')
from services import background, vector_store, ai_policy
from services.brain_sync_service import brain_sync_service
background.schedule = lambda coro: coro.close()
brain_sync_service.update_config(str(root/'brain'), False)
from fastapi.testclient import TestClient
import main
c = TestClient(main.app, headers={'X-Gyrus-Token': main.API_TOKEN}, raise_server_exceptions=False)
results = {}
def create(title):
    r=c.post('/api/bookmarks',json={'title':title,'url':f'https://example.com/{title}'})
    assert r.status_code == 201, (r.status_code,r.text)
    return r.json()
def reset():
    assert c.post('/api/data/clear-bookmarks').status_code == 200

create('keep-before-wrong-json')
r=c.post('/api/data/restore',json={'unrelated':'configuration'})
results['unrelated_json_restore']={'http':r.status_code,'bookmarks_after':len(c.get('/api/bookmarks').json())}

for name,label in [('', 'blank'),('x'*256,'long')]:
    reset()
    created=c.post('/api/collections',json={'name':name})
    backup=c.get('/api/data/backup').json()
    restored=c.post('/api/data/restore',json=backup)
    results[f'{label}_folder_backup_roundtrip']={'create_http':created.status_code,'restore_http':restored.status_code}
reset()
first=c.post('/api/collections',json={'name':'duplicate'}).json()
results['duplicate_folder']={'http':c.post('/api/collections',json={'name':'duplicate'}).status_code}
results['missing_parent']={'http':c.post('/api/collections',json={'name':'orphan','parent_id':'does-not-exist'}).status_code}
results['null_folder_name']={'http':c.put('/api/collections/'+first['id'],json={'name':None}).status_code}
a=c.post('/api/tags',json={'name':'first'}).json()
b=c.post('/api/tags',json={'name':'second'}).json()
results['duplicate_tag_rename']={'http':c.put('/api/tags/'+b['id'],json={'name':a['name']}).status_code}
reset()
parent=None
for i in range(65):
    r=c.post('/api/collections',json={'name':f'level-{i}','parent_id':parent})
    assert r.status_code==201, (i,r.status_code)
    parent=r.json()['id']
r=c.post('/api/data/restore',json=c.get('/api/data/backup').json())
results['deep_folder_backup_roundtrip']={'created_levels':65,'restore_http':r.status_code}
reset()
old_limit=main.MAX_REQUEST_BYTES
main.MAX_REQUEST_BYTES=128
payload=json.dumps({'title':'x'*300,'url':'https://example.com/chunked'}).encode()
normal=c.post('/api/bookmarks',content=payload,headers={'Content-Type':'application/json'})
chunked=c.post('/api/bookmarks',content=iter([payload]),headers={'Content-Type':'application/json'})
results['request_body_limit']={'configured_bytes':128,'payload_bytes':len(payload),'content_length_http':normal.status_code,'chunked_http':chunked.status_code}
main.MAX_REQUEST_BYTES=old_limit
reset()
ai_policy.configure(True)
r=c.post('/api/data/factory-reset')
results['factory_reset_ai']={'http':r.status_code,'ai_enabled_after':ai_policy.enabled()}
ai_policy.configure(False)
vector_store.reset_table(3)
assert vector_store.upsert('synthetic',[.1,.2,.3])
write=vector_store.upsert('synthetic',[.1,.2])
results['failed_vector_replace']={'replacement_success':write,'vectors_remaining':vector_store.count()}
Path('/tmp/gyrus-meta-review/probe-results.json').write_text(json.dumps(results,indent=2))
print(json.dumps(results,indent=2))
c.close()
