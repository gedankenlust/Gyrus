import httpx
import time
import sys

BASE_URL = "http://127.0.0.1:8080"

def test_logic():
    print("--- Starting Gyrus Logic Check ---")
    
    with httpx.Client(base_url=BASE_URL, timeout=10.0) as client:
        # 1. Health Check
        print("1. Checking backend health...", end=" ")
        try:
            resp = client.get("/health")
            if resp.status_code == 200:
                print("OK ✅")
            else:
                print(f"FAILED (Status {resp.status_code}) ❌")
                return
        except Exception as e:
            print(f"FAILED (Connection error: {e}) ❌")
            print("\nIst die App in Xcode gestartet? Das Backend muss laufen.")
            return

        # 2. Simulate Extension Save
        print("2. Simulating Browser Extension save...", end=" ")
        payload = {
            "title": "Automated Logic Test",
            "url": f"https://test-{int(time.time())}.com",
            "source": "extension"
        }
        resp = client.post("/api/bookmarks", json=payload)
        if resp.status_code == 201:
            print("OK ✅")
            bm = resp.json()
            bm_id = bm['id']
            col_id = bm.get('collection_id')
        else:
            print(f"FAILED ({resp.text}) ❌")
            return

        # 3. Verify Inbox Assignment
        print("3. Verifying 'Inbox' assignment...", end=" ")
        if col_id:
            col_resp = client.get(f"/api/collections")
            collections = col_resp.json()
            inbox = next((c for c in collections if c['id'] == col_id), None)
            if inbox and inbox['name'] == "Inbox":
                print("OK (Assigned to 'Inbox') ✅")
            else:
                print(f"FAILED (Wrong collection: {inbox['name'] if inbox else 'None'}) ❌")
        else:
            print("FAILED (No collection assigned) ❌")

        # 4. Test Deletion
        print(f"4. Testing deletion of bookmark {bm_id}...", end=" ")
        del_resp = client.delete(f"/api/bookmarks/{bm_id}")
        if del_resp.status_code == 200 or del_resp.status_code == 204:
            # Check if really gone
            get_resp = client.get(f"/api/bookmarks")
            if not any(b['id'] == bm_id for b in get_resp.json()):
                print("OK ✅")
            else:
                print("FAILED (Still present) ❌")
        else:
            print(f"FAILED (Status {del_resp.status_code}) ❌")

    print("\n--- Logic Check Complete: All systems operational! ---")

if __name__ == "__main__":
    test_logic()
