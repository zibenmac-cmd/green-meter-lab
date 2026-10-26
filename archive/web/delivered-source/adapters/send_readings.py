#!/usr/bin/env python3
"""Forward real meter JSON lines on stdin to a private Sites ingestion endpoint.
No simulated readings are generated. Configuration uses environment variables.
"""
import json, os, sys, time
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse

def main():
    site=os.environ.get('METER_SITE_URL','').rstrip('/')
    key=os.environ.get('METER_INGEST_KEY','')
    access=os.environ.get('METER_SITE_ACCESS_TOKEN','')
    parsed=urlparse(site)
    if parsed.scheme!='https' and not(parsed.scheme=='http' and parsed.hostname in ('127.0.0.1','localhost')):
        raise SystemExit('METER_SITE_URL must be an HTTPS Site origin (or localhost for development).')
    if parsed.path or parsed.query or parsed.fragment:
        raise SystemExit('METER_SITE_URL must contain only the Site origin.')
    if not key:raise SystemExit('Set METER_INGEST_KEY before starting.')
    if parsed.hostname not in ('127.0.0.1','localhost') and not access:
        raise SystemExit('A private Site also requires METER_SITE_ACCESS_TOKEN.')
    for index,line in enumerate(sys.stdin,1):
        if not line.strip():continue
        try:
            reading=json.loads(line)
            if not isinstance(reading,dict) or any(k not in reading for k in ('device_id','timestamp','power_w','energy_kwh')):
                raise ValueError('expected device_id, timestamp, power_w, energy_kwh')
        except (ValueError,TypeError):
            print(f'Line {index}: invalid reading format.',file=sys.stderr);return 1
        headers={'Content-Type':'application/json','Authorization':'Bearer '+key}
        if access:headers['OAI-Sites-Authorization']='Bearer '+access
        body=json.dumps(reading).encode('utf-8')
        for attempt in range(5):
            try:
                with urlopen(Request(site+'/api/ingest',data=body,headers=headers,method='POST'),timeout=20) as response:
                    if response.headers.get('Content-Type','').split(';')[0]!='application/json':
                        raise SystemExit('Server returned a sign-in page; check private Site access token.')
                    result=json.load(response)
                    print(f'Line {index}: inserted={result.get("inserted",0)}, duplicates={result.get("duplicates",0)}',flush=True)
                break
            except HTTPError as error:
                if error.code<500:
                    print(f'Line {index}: HTTP {error.code}; check access, ingest key, timestamp and payload.',file=sys.stderr);return 1
                if attempt==4:print(f'Line {index}: server unavailable after retries.',file=sys.stderr);return 1
                time.sleep(2**attempt)
            except (URLError,TimeoutError,OSError):
                if attempt==4:print(f'Line {index}: network unavailable after retries.',file=sys.stderr);return 1
                time.sleep(2**attempt)
    return 0
if __name__=='__main__':
    try:sys.exit(main())
    except KeyboardInterrupt:sys.exit(130)
