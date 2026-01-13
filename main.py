# BucketButler - Secure GCS Media Gateway
# Author: Bopaiah Mekerira
# LinkedIn: https://www.linkedin.com/in/bopaiah/
# Description: High-performance, ACL-protected streaming for Google Cloud Storage.

import functions_framework
from google.cloud import storage
import time
import os

# Initialize client outside the function for better performance (warm starts)
storage_client = storage.Client()
BUCKET_NAME = os.environ.get('BUCKET_NAME', 'BUCKET_NAME_PLACEHOLDER')
ACL_FILE = os.environ.get('ACL_FILE', 'bucketlist.acl')

# Global cache for ACL to avoid GCS reads on every request
_ALLOWED_FOLDERS = None
_ACL_LAST_LOADED = 0
ACL_CACHE_SECONDS = 300  # 5 minutes

def get_allowed_folders():
    global _ALLOWED_FOLDERS, _ACL_LAST_LOADED
    now = time.time()
    
    if _ALLOWED_FOLDERS is not None and (now - _ACL_LAST_LOADED) < ACL_CACHE_SECONDS:
        return _ALLOWED_FOLDERS
    
    try:
        bucket = storage_client.bucket(BUCKET_NAME)
        blob = bucket.blob(ACL_FILE)
        if blob.exists():
            content = blob.download_as_text()
            # Strip whitespace, remove trailing slashes, ignore empty/comments
            folders = [l.strip().rstrip('/') for l in content.splitlines() 
                      if l.strip() and not l.strip().startswith('#')]
            _ALLOWED_FOLDERS = folders
            _ACL_LAST_LOADED = now
            print(f"Updated ACL: {_ALLOWED_FOLDERS}")
            return _ALLOWED_FOLDERS
        else:
            print(f"CRITICAL: {ACL_FILE} missing in bucket root.")
            return []
    except Exception as e:
        print(f"Error fetching ACL: {e}")
        return _ALLOWED_FOLDERS if _ALLOWED_FOLDERS is not None else []

@functions_framework.http
def stream_file(request):
    # Health Check (Always allowed)
    if request.path == '/health':
        return 'OK', 200

    # Remove leading slash (e.g., /logo.png -> logo.png)
    file_path = request.path.lstrip('/')
    
    # Strip well-known gateway prefixes
    if file_path.startswith('media/'):
        file_path = file_path[len('media/'):]

    if not file_path:
        return 'No file path provided', 400

    # Security: Explicitly block access to the ACL file itself
    if file_path == ACL_FILE:
        return 'Access Denied', 403

    # ACL Verification
    allowed_folders = get_allowed_folders()
    is_allowed = any(file_path.startswith(f + '/') for f in allowed_folders)
    
    if not is_allowed:
        print(f"ACL Blocked: {file_path}")
        return 'Access Denied', 403

    try:
        bucket = storage_client.bucket(BUCKET_NAME)
        blob = bucket.blob(file_path)
        
        if not blob.exists():
            print(f"File not found: {file_path}")
            return 'File not found', 404

        blob.reload()

        if request.method == 'HEAD':
            return '', 200, {'Content-Type': blob.content_type}

        def generate():
            with blob.open("rb") as f:
                while chunk := f.read(256*1024):
                    yield chunk

        headers = {
            'Content-Type': blob.content_type or 'application/octet-stream'
        }
        return generate(), 200, headers

    except Exception as e:
        print(f"Error serving {file_path}: {str(e)}")
        return 'Internal Server Error', 500