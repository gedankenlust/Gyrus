import os, tempfile, time, statistics, json, uuid
from pathlib import Path
root=Path(tempfile.mkdtemp(prefix='gyrus-meta-perf-'))
os.environ['GYRUS_DATA_DIR']=str(root)
os.environ['GYRUS_BRAIN_ROOT']=str(root/'brain')
from alembic import command
from alembic.config import Config
command.upgrade(Config('alembic.ini'),'head')
from database import SessionLocal
from sqlalchemy import insert
from models.bookmark import Bookmark
from fastapi.testclient import TestClient
import main
client=TestClient(main.app,headers={'X-Gyrus-Token':main.API_TOKEN})
results=[]
previous=0
for size in (1000,10000):
    rows=[{'id':str(uuid.uuid4()),'url':f'https://example.com/item-{i}','title':f'Benchmark Bookmark {i}', 'description':'Synthetic audit fixture', 'scraped_content':'Synthetic content for isolated performance measurement. '*20} for i in range(previous,size)]
    with SessionLocal() as session:
        session.execute(insert(Bookmark),rows)
        session.commit()
    for route in ('/api/bookmarks?limit=100','/api/bookmarks/counts','/api/search?q=Benchmark&limit=100','/api/data/backup'):
        times=[]
        for _ in range(3):
            start=time.perf_counter()
            r=client.get(route)
            times.append((time.perf_counter()-start)*1000)
            assert r.status_code==200,(route,r.status_code)
        results.append({'bookmarks':size,'route':route,'median_ms':round(statistics.median(times),1),'response_bytes':len(r.content)})
    previous=size
Path('/tmp/gyrus-meta-review/benchmark-results.json').write_text(json.dumps(results,indent=2))
print(json.dumps(results,indent=2))
