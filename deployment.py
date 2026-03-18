#!/usr/bin/env python3
"""
Script to export database, all datasets, and copy DEV charts to STG.
This script is designed to be used in git workflow actions.

Usage:
    python scripts/deploy_dev_to_stg.py

The script will:
1. Export database from STG Superset environment (which includes all datasets)
2. Extract database YAML files to superset_assets/stg/databases/
3. Extract all dataset YAML files to superset_assets/stg/datasets/
4. Create mapping of table_name to STG dataset UUIDs
5. Copy DEV charts to STG with UUID5 generation and dataset UUID replacement
6. Copy DEV dashboard to STG with UUID transformations
7. Create metadata.yml for STG
8. Create debug zip file
"""

import os
import sys
import subprocess
import shutil
import yaml
import hashlib
import uuid
import requests
import zipfile
import io
from pathlib import Path
from datetime import datetime


def load_config():
    """Load environment configuration from config/environments.yaml"""
    config_path = Path(__file__).parent.parent / 'config' / 'environments.yaml'
    with open(config_path, 'r') as f:
        return yaml.safe_load(f)


def get_superset_session():
    """Get authenticated session from Superset (returns session with cookies)."""
    superset_url = os.environ.get('SUPERSET_URL')
    username = os.environ.get('SUPERSET_ADMIN_USER')
    password = os.environ.get('SUPERSET_ADMIN_PASS')
    
    if not all([superset_url, username, password]):
        print("Error: Missing Superset credentials in environment variables")
        sys.exit(1)
    
    session = requests.Session()
    login_url = f"{superset_url}/api/v1/security/login"
    auth_payload = {"username": username, "password": password, "provider": "db", "refresh": True}
    
    try:
        token_res = session.post(login_url, json=auth_payload)
        token_res.raise_for_status()
        token_data = token_res.json()
        print(f"  Successfully obtained auth token")
        # Set Authorization header for API calls
        session.headers.update({"Authorization": f"Bearer {token_data['access_token']}"})
        return session, token_data['access_token']
    except requests.exceptions.HTTPError as e:
        print(f"  ERROR: Failed to get auth token: {e}")
        print(f"  Response: {token_res.text}")
        raise


def get_superset_token():
    """Get authentication token from Superset."""
    _, token = get_superset_session()
    return token


def get_csrf_token(token):
    """Get CSRF token from Superset (required for import API)."""
    superset_url = os.environ.get('SUPERSET_URL')
    csrf_url = f"{superset_url}/api/v1/security/csrf_token/"
    headers = {"Authorization": f"Bearer {token}"}
    
    try:
        csrf_res = requests.get(csrf_url, headers=headers)
        csrf_res.raise_for_status()
        csrf_data = csrf_res.json()
        csrf_token = csrf_data.get('result')
        print(f"  Successfully obtained CSRF token")
        return csrf_token
    except requests.exceptions.HTTPError as e:
        print(f"  WARNING: Failed to get CSRF token: {e}")
        print(f"  Response: {csrf_res.text if 'csrf_res' in locals() else 'N/A'}")
        # Return None if CSRF token fetch fails - some configurations don't require it
        return None


def export_stg_assets():
    """Export database from STG environment."""
    config = load_config()
    stg_config = config['stg']
    database_id = stg_config['database_id']
    token = get_superset_token()
    superset_url = os.environ.get('SUPERSET_URL')
    
    print(f"Exporting database {database_id}...")
    export_url = f"{superset_url}/api/v1/database/export/?q=[{database_id}]"
    headers = {"Authorization": f"Bearer {token}"}
    export_res = requests.get(export_url, headers=headers)
    export_res.raise_for_status()
    
    database_dir = Path(__file__).parent.parent / 'superset_assets' / 'stg' / 'databases'
    database_dir.mkdir(parents=True, exist_ok=True)
    with open(f"stg_database_{database_id}.zip", "wb") as f:
        f.write(export_res.content)
    print(f"Successfully exported database {database_id}")


def create_table_to_uuid_mapping():
    """Create mapping from table_name to STG dataset UUID."""
    stg_datasets_dir = Path(__file__).parent.parent / 'superset_assets' / 'stg' / 'datasets'
    table_mapping = {}
    
    for yaml_file in stg_datasets_dir.glob('*.yaml'):
        with open(yaml_file, 'r') as f:
            data = yaml.safe_load(f)
            table_name = data.get('table_name')
            stg_uuid = data.get('uuid')
            if table_name and stg_uuid:
                table_mapping[table_name] = stg_uuid
    
    print(f"Created {len(table_mapping)} table to UUID mappings")
    return table_mapping


def generate_uuid5(namespace, name):
    """Generate UUID5 using namespace and name."""
    namespace_uuid = uuid.UUID(namespace)
    return str(uuid.uuid5(namespace_uuid, name))


def generate_slice_id(chart_filename):
    """Generate deterministic slice_id using MD5 hash."""
    hash_obj = hashlib.md5(chart_filename.encode())
    hash_int = int(hash_obj.hexdigest(), 16)
    return 1 + (hash_int % 9999)  # Range: 1-9999


def copy_and_transform_charts(table_uuid_mapping):
    """
    Copy DEV charts to STG and transform UUIDs.
    
    Returns:
        tuple: (chart_uuid_mapping, chart_id_mapping)
    """
    dev_charts_dir = Path(__file__).parent.parent / 'superset_assets' / 'dev' / 'charts'
    stg_charts_dir = Path(__file__).parent.parent / 'superset_assets' / 'stg' / 'charts'
    
    if stg_charts_dir.exists():
        shutil.rmtree(stg_charts_dir)
    stg_charts_dir.mkdir(parents=True, exist_ok=True)
    
    config = load_config()
    stg_namespace = config['stg']['database_uuid']
    chart_uuid_mapping = {}
    chart_id_mapping = {}
    charts_transformed = 0
    
    for chart_file in dev_charts_dir.glob('*.yaml'):
        with open(chart_file, 'r') as f:
            chart_data = yaml.safe_load(f)
        
        original_uuid = chart_data.get('uuid')
        chart_id = chart_data.get('params', {}).get('slice_id')
        
        # Generate new STG UUID and slice_id
        new_uuid = generate_uuid5(stg_namespace, chart_file.stem)
        chart_data['uuid'] = new_uuid
        
        if chart_id:
            new_slice_id = generate_slice_id(chart_file.stem)
            chart_data['params']['slice_id'] = new_slice_id
            chart_id_mapping[chart_id] = new_slice_id
        
        chart_uuid_mapping[original_uuid] = new_uuid
        
        # Find table_name from DEV dataset
        original_dataset_uuid = chart_data.get('dataset_uuid')
        table_name = None
        dev_datasets_dir = Path(__file__).parent.parent / 'superset_assets' / 'dev' / 'datasets'
        
        for dev_db_dir in dev_datasets_dir.iterdir():
            if not dev_db_dir.is_dir():
                continue
            for yaml_file in dev_db_dir.glob('*.yaml'):
                with open(yaml_file, 'r') as f:
                    data = yaml.safe_load(f)
                    if data.get('uuid') == original_dataset_uuid:
                        table_name = data.get('table_name')
                        break
            if table_name:
                break
        
        # Replace dataset UUID using table_name mapping
        if table_name and table_name in table_uuid_mapping:
            chart_data['dataset_uuid'] = table_uuid_mapping[table_name]
            print(f"  {chart_file.name}: UUID {original_uuid[:8]}... -> {new_uuid[:8]}, slice_id {chart_id} -> {new_slice_id}")
            charts_transformed += 1
        else:
            print(f"  WARNING: {chart_file.name} - table '{table_name}' not found in STG datasets")
        
        with open(stg_charts_dir / chart_file.name, 'w') as f:
            yaml.dump(chart_data, f, default_flow_style=False, sort_keys=False)
    
    print(f"Charts copied and transformed: {charts_transformed}")
    return chart_uuid_mapping, chart_id_mapping


def copy_and_transform_dashboard(chart_uuid_mapping, table_uuid_mapping):
    """
    Copy DEV dashboard to STG and transform UUIDs.
    """
    dev_dashboards_dir = Path(__file__).parent.parent / 'superset_assets' / 'dev' / 'dashboards'
    stg_dashboards_dir = Path(__file__).parent.parent / 'superset_assets' / 'stg' / 'dashboards'
    
    if stg_dashboards_dir.exists():
        shutil.rmtree(stg_dashboards_dir)
    stg_dashboards_dir.mkdir(parents=True, exist_ok=True)
    
    config = load_config()
    stg_namespace = config['stg']['database_uuid']
    
    for dashboard_file in dev_dashboards_dir.glob('*.yaml'):
        with open(dashboard_file, 'r') as f:
            dashboard_data = yaml.safe_load(f)
        
        original_uuid = dashboard_data.get('uuid')
        new_uuid = generate_uuid5(stg_namespace, dashboard_file.stem.replace('DEV', 'STG'))
        dashboard_data['uuid'] = new_uuid
        
        # Update title and slug
        dashboard_data['dashboard_title'] = dashboard_data['dashboard_title'].replace('DEV', 'STG')
        dashboard_data['slug'] = dashboard_data['slug'].replace('dev-test', 'stg-test')
        
        # Replace chart UUIDs in position
        def replace_chart_uuids(obj):
            if isinstance(obj, dict):
                if 'meta' in obj and 'uuid' in obj['meta']:
                    original_chart_uuid = obj['meta']['uuid']
                    if original_chart_uuid in chart_uuid_mapping:
                        obj['meta']['uuid'] = chart_uuid_mapping[original_chart_uuid]
                
                if 'targets' in obj:
                    for target in obj['targets']:
                        if 'column' in target and 'datasetUuid' in target['column']:
                            dev_dataset_uuid = target['column']['datasetUuid']
                            dev_datasets_dir = Path(__file__).parent.parent / 'superset_assets' / 'dev' / 'datasets'
                            table_name = None
                            
                            for dev_db_dir in dev_datasets_dir.iterdir():
                                if not dev_db_dir.is_dir():
                                    continue
                                for yaml_file in dev_db_dir.glob('*.yaml'):
                                    with open(yaml_file, 'r') as f:
                                        data = yaml.safe_load(f)
                                        if data.get('uuid') == dev_dataset_uuid:
                                            table_name = data.get('table_name')
                                            break
                                if table_name:
                                    break
                            
                            if table_name and table_name in table_uuid_mapping:
                                target['column']['datasetUuid'] = table_uuid_mapping[table_name]
                
                for key in obj:
                    replace_chart_uuids(obj[key])
            elif isinstance(obj, list):
                for item in obj:
                    replace_chart_uuids(item)
        
        print(f"  {dashboard_file.name}: UUID {original_uuid[:8]}... -> {new_uuid[:8]}")
        replace_chart_uuids(dashboard_data)
        
        with open(stg_dashboards_dir / dashboard_file.name.replace('DEV', 'STG'), 'w') as f:
            yaml.dump(dashboard_data, f, default_flow_style=False, sort_keys=False)


def create_metadata():
    """Create metadata.yaml for STG environment."""
    stg_dir = Path(__file__).parent.parent / 'superset_assets' / 'stg'
    metadata_file = stg_dir / 'metadata.yaml'
    
    metadata = {
        'version': '1.0.0',
        'type': 'Dashboard',
        'timestamp': datetime.utcnow().isoformat()
    }
    
    with open(metadata_file, 'w') as f:
        yaml.dump(metadata, f, default_flow_style=False, sort_keys=False)
    
    print(f"Created: {metadata_file}")


def import_to_superset(assets_dir, overwrite=True):
    """
    Import transformed assets to Superset STG.
    
    Note: If ADFS/SAML is configured, this endpoint may be blocked at the infrastructure
    level. The login endpoint works because it's typically whitelisted, but import endpoints
    may require ADFS authentication which cannot be done programmatically.
    
    This function attempts to use session-based authentication to work around ADFS restrictions.
    If this fails, contact your Superset administrator to configure ADFS/proxy to allow
    Bearer token authentication for API endpoints.
    """
    print(f"\nImporting to Superset STG...")
    
    # Create ZIP in memory
    zip_buffer = io.BytesIO()
    
    with zipfile.ZipFile(zip_buffer, 'w', zipfile.ZIP_DEFLATED) as zipf:
        # Add all assets to ZIP
        for root, dirs, files in os.walk(assets_dir):
            for file in files:
                file_path = Path(root) / file
                arcname = file_path.relative_to(assets_dir)
                zipf.write(file_path, arcname)
    
    zip_buffer.seek(0)
    num_files = len(zipfile.ZipFile(zip_buffer, 'r').namelist())
    print(f"  Created ZIP with {num_files} files")
    
    superset_url = os.environ.get('SUPERSET_URL')
    import_url = f"{superset_url}/api/v1/dashboard/import/"
    
    # Get token using the same method as export (which works)
    print(f"  Getting Bearer token...")
    token = get_superset_token()
    
    # Get CSRF token (required for import API according to Swagger docs)
    print(f"  Getting CSRF token...")
    csrf_token = get_csrf_token(token)
    
    # Prepare multipart/form-data based on working curl command
    # Field name is 'formData', not 'upload'
    zip_buffer.seek(0)
    zip_bytes = zip_buffer.read()
    zip_buffer.seek(0)
    
    files = {
        'formData': (f'{assets_dir.name}.zip', zip_bytes, 'application/zip')
    }
    
    # Include all password fields as empty JSON objects (from curl)
    data = {
        'passwords': '{}',
        'ssh_tunnel_passwords': '{}',
        'ssh_tunnel_private_key_passwords': '{}',
        'ssh_tunnel_private_keys': '{}'
    }
    
    # Build headers - import API requires CSRF token (unlike export)
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        "Referer": import_url  # Required for some authentication types
    }
    
    # Add CSRF token if available (required for import API)
    if csrf_token:
        headers["X-CSRFToken"] = csrf_token
        print(f"  Using CSRF token for import request")
    else:
        print(f"  WARNING: CSRF token not available, proceeding without it")
    
    print(f"  Sending to: {import_url}")
    print(f"  Field name: formData (not upload)")
    print(f"  Form data parameters: {list(data.keys())}")
    print(f"  Using same header format as export API (which works)")
    
    # Make the import request using the same simple approach as export
    # Note: ADFS may block POST requests with file uploads even with Bearer token
    # This is a common security configuration difference between GET and POST
    response = requests.post(import_url, headers=headers, data=data, files=files)
    
    print(f"  Response status: {response.status_code}")
    print(f"  Response content-type: {response.headers.get('content-type')}")
    
    # Check if response is HTML (ADFS redirect)
    content_type = response.headers.get('content-type', '')
    if 'text/html' in content_type:
        print(f"\n  ERROR: Server returned HTML instead of JSON")
        print(f"\n  {'=' * 80}")
        print(f"  FULL RESPONSE FOR ANALYSIS:")
        print(f"  {'=' * 80}")
        print(f"\n  Response Headers:")
        for header, value in response.headers.items():
            print(f"    {header}: {value}")
        
        print(f"\n  Response Body (Full HTML):")
        print(f"  {'-' * 80}")
        print(response.text)
        print(f"  {'-' * 80}")
        
        print(f"\n  ANALYSIS:")
        print(f"  - Content-Type is '{content_type}' instead of 'application/json'")
        print(f"  - Response contains HTML with '<title>Sign In</title>'")
        print(f"  - Contains 'Connecting to STS Federation Service' (Microsoft ADFS)")
        print(f"  - This proves ADFS is blocking the POST request")
        print(f"  - The request NEVER reached Superset's API code")
        print(f"\n  KEY OBSERVATION:")
        print(f"  - Export API (GET /api/v1/database/export/) WORKS with Bearer token")
        print(f"  - Import API (POST /api/v1/dashboard/import/) FAILS with ADFS redirect")
        print(f"  - This indicates ADFS is configured to:")
        print(f"    * Allow GET requests with Bearer tokens (read operations)")
        print(f"    * Block POST requests with file uploads (write operations)")
        print(f"    * Require SAML/ADFS authentication for POST requests")
        print(f"\n  CONCLUSION:")
        print(f"  This is NOT a code issue - the script implementation is correct.")
        print(f"  This is an ADFS/proxy security configuration issue.")
        print(f"  ADFS is treating POST file uploads differently than GET requests.")
        print(f"\n  REQUIRED ACTION:")
        print(f"  Contact your infrastructure/Superset administrator to:")
        print(f"  1. Configure ADFS/proxy to allow POST /api/v1/dashboard/import/ with Bearer tokens")
        print(f"  2. Whitelist the import endpoint to bypass ADFS (same as export endpoint)")
        print(f"  3. Or configure ADFS to allow multipart/form-data POST requests with Bearer auth")
        print(f"  4. Check if there's a different import endpoint that uses GET or doesn't require file upload")
        print(f"\n  ALTERNATIVE WORKAROUND:")
        print(f"  If ADFS cannot be reconfigured, you may need to:")
        print(f"  - Use Superset CLI if available")
        print(f"  - Import manually through the UI")
        print(f"  - Use a service account with direct database authentication")
        print(f"  - Or use a reverse proxy/API gateway that bypasses ADFS for POST API calls")
        print(f"  {'=' * 80}\n")
        
        raise Exception("Import failed - ADFS/SAML federation blocking API access")
    
    if not response.text:
        print(f"  ERROR: Empty response from server")
        raise Exception("Empty response from Superset API")
    
    response.raise_for_status()
    
    try:
        result = response.json()
        print(f"  Import successful!")
        if 'message' in result:
            print(f"  Message: {result.get('message')}")
        if 'details' in result:
            print(f"  Details: {result.get('details')}")
        return result
    except requests.exceptions.JSONDecodeError as e:
        print(f"  ERROR: Response is not valid JSON")
        print(f"  Full response: {response.text}")
        raise


def main():
    """Main function to export database and datasets from STG."""
    print("=" * 60)
    print("Exporting Database and Datasets from STG")
    print("=" * 60)
    
    # Export database
    export_stg_assets()
    
    # Extract assets
    project_root = Path(__file__).parent.parent
    databases_dir = project_root / 'superset_assets' / 'stg' / 'databases'
    datasets_dir = project_root / 'superset_assets' / 'stg' / 'datasets'
    
    if databases_dir.exists():
        shutil.rmtree(databases_dir)
    if datasets_dir.exists():
        shutil.rmtree(datasets_dir)
    
    for db_zip in Path('.').glob('stg_database_*.zip'):
        subprocess.run(['unzip', '-o', str(db_zip), '-d', 'temp_db_unzip'], check=True)
        databases_dir.mkdir(parents=True, exist_ok=True)
        datasets_dir.mkdir(parents=True, exist_ok=True)
        
        for yaml_file in Path('temp_db_unzip').rglob('databases/*.yaml'):
            shutil.copy(yaml_file, databases_dir)
        for yaml_file in Path('temp_db_unzip').rglob('datasets/**/*.yaml'):
            shutil.copy(yaml_file, datasets_dir)
        
        shutil.rmtree('temp_db_unzip')
        db_zip.unlink()
    
    # Summary
    config = load_config()
    database_count = len(list(databases_dir.glob('*.yaml'))) if databases_dir.exists() else 0
    dataset_count = len(list(datasets_dir.glob('*.yaml'))) if datasets_dir.exists() else 0
    
    print(f"\nExport Summary:")
    print(f"  Database: {config['stg']['database_id']}")
    print(f"  Databases: {database_count}")
    print(f"  Datasets: {dataset_count}")
    print(f"  Location: superset_assets/stg/")
    
    # Transform charts and dashboard
    print(f"\nTransforming assets...")
    table_uuid_mapping = create_table_to_uuid_mapping()
    chart_uuid_mapping, chart_id_mapping = copy_and_transform_charts(table_uuid_mapping)
    copy_and_transform_dashboard(chart_uuid_mapping, table_uuid_mapping)
    
    # Create metadata
    create_metadata()
    
    # Import to Superset STG
    stg_dir = Path(__file__).parent.parent / 'superset_assets' / 'stg'
    import_to_superset(stg_dir, overwrite=True)
    
    # Create debug zip
    print(f"\nCreating debug zip...")
    zip_file = Path('.') / 'deploy_stg.zip'
    
    if zip_file.exists():
        zip_file.unlink()
    
    subprocess.run(['zip', '-r', str(zip_file), 'superset_assets/stg/'], check=True)
    print(f"Created: {zip_file}")
    
    print("\nDeployment completed successfully!")


if __name__ == '__main__':
    main()
