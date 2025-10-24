#!/usr/bin/env python3

import os
import sys
import json
import requests
from typing import Dict, List, Optional
from .base import DNSProvider, DNSRecord, CAARecord, RecordType


class CloudflareDNSProvider(DNSProvider):
    """DNS provider implementation for Cloudflare."""

    DETECT_ENV = "CLOUDFLARE_API_TOKEN"

    # Certbot configuration
    CERTBOT_PLUGIN = "dns-cloudflare"
    CERTBOT_PLUGIN_MODULE = "certbot_dns_cloudflare"
    CERTBOT_PACKAGE = "certbot-dns-cloudflare==4.0.0"
    CERTBOT_PROPAGATION_SECONDS = 120
    CERTBOT_CREDENTIALS_FILE = "~/.cloudflare/cloudflare.ini"

    def __init__(self):
        super().__init__()
        self.api_token = os.getenv("CLOUDFLARE_API_TOKEN")
        if not self.api_token:
            raise ValueError("CLOUDFLARE_API_TOKEN environment variable is required")
        self.base_url = "https://api.cloudflare.com/client/v4"
        self.headers = {
            "Authorization": f"Bearer {self.api_token}",
            "Content-Type": "application/json",
        }
        self.zone_id: Optional[str] = None  # Will be set when needed
        self.zone_domain: Optional[str] = None  # Cache the domain for the zone

    def setup_certbot_credentials(self) -> bool:
        """Setup Cloudflare credentials file for certbot."""
        credentials_file = os.path.expanduser(self.CERTBOT_CREDENTIALS_FILE)
        credentials_dir = os.path.dirname(credentials_file)

        try:
            # Create credentials directory
            os.makedirs(credentials_dir, exist_ok=True)

            # Write credentials file
            with open(credentials_file, "w") as f:
                f.write(f"dns_cloudflare_api_token = {self.api_token}\n")

            # Set secure permissions
            os.chmod(credentials_file, 0o600)
            print(f"Cloudflare credentials file created: {credentials_file}")

            # Pre-fetch zone ID if we have a domain
            domain = os.getenv("DOMAIN")
            if domain:
                self._ensure_zone_id(domain)

            return True

        except Exception as e:
            print(f"Error setting up Cloudflare credentials: {e}", file=sys.stderr)
            return False

    def _make_request(
        self, method: str, endpoint: str, data: Optional[Dict] = None
    ) -> Dict:
        """Make a request to the Cloudflare API with error handling."""
        url = f"{self.base_url}/{endpoint}"
        try:
            if method.upper() == "GET":
                response = requests.get(url, headers=self.headers)
            elif method.upper() == "POST":
                response = requests.post(url, headers=self.headers, json=data)
            elif method.upper() == "DELETE":
                response = requests.delete(url, headers=self.headers)
            else:
                raise ValueError(f"Unsupported HTTP method: {method}")

            response.raise_for_status()
            result = response.json()

            if not result.get("success", False):
                errors = result.get("errors", [])
                error_msg = "\n".join(
                    [
                        f"Code: {e.get('code')}, Message: {e.get('message')}"
                        for e in errors
                    ]
                )
                print(f"API Error: {error_msg}", file=sys.stderr)
                if data:
                    print(f"Request data: {json.dumps(data)}", file=sys.stderr)
                return {"success": False, "errors": errors}

            return result
        except requests.exceptions.RequestException as e:
            print(f"Request Error: {str(e)}", file=sys.stderr)
            if data:
                print(f"Request data: {json.dumps(data)}", file=sys.stderr)
            return {"success": False, "errors": [{"message": str(e)}]}
        except json.JSONDecodeError:
            print("JSON Decode Error: Could not parse response", file=sys.stderr)
            return {
                "success": False,
                "errors": [{"message": "Could not parse response"}],
            }
        except Exception as e:
            print(f"Unexpected Error: {str(e)}", file=sys.stderr)
            return {"success": False, "errors": [{"message": str(e)}]}

    def _get_zone_info(self, domain: str) -> Optional[tuple[str, str]]:
        """Get the zone ID and zone name for a domain."""
        zone_name_len = 0
        zone_id = None
        zone_name_found = None

        page = 1
        total_pages = 1

        while page <= total_pages:
            result = self._make_request("GET", f"zones?page={page}")

            if not result.get("success", False):
                return None

            zones = result.get("result", [])
            if not zones and page == 1:
                print("No zones found for any domain", file=sys.stderr)
                return None

            result_info = result.get("result_info", {})
            if result_info:
                total_pages = result_info.get("total_pages", total_pages)

            for zone in zones:
                zone_name = zone.get("name", "")
                if domain == zone_name:
                    return (zone.get("id"), zone_name)
                if domain.endswith(f".{zone_name}") and len(zone_name) > zone_name_len:
                    zone_name_len = len(zone_name)
                    zone_id = zone.get("id")
                    zone_name_found = zone_name

            page += 1

        if zone_id and zone_name_found:
            return (zone_id, zone_name_found)
        else:
            print(
                f"Zone ID not found in response for domain: {domain}", file=sys.stderr
            )
            return None

    def _ensure_zone_id(self, domain: str) -> Optional[str]:
        """Ensure we have a zone ID for the domain, fetching if necessary."""
        if self.zone_id and self.zone_domain:
            if domain == self.zone_domain or domain.endswith(f".{self.zone_domain}"):
                return self.zone_id

        zone_info = self._get_zone_info(domain)
        if zone_info:
            self.zone_id, self.zone_domain = zone_info
        return self.zone_id

    def get_dns_records(
        self, name: str, record_type: Optional[RecordType] = None
    ) -> List[DNSRecord]:
        """Get DNS records for a domain."""
        zone_id = self._ensure_zone_id(name)
        if not zone_id:
            print(f"Error: Could not find zone for domain {name}", file=sys.stderr)
            return []

        params = f"zones/{zone_id}/dns_records?name={name}"
        if record_type:
            params += f"&type={record_type.value}"

        print(f"Checking for existing DNS records for {name}")
        result = self._make_request("GET", params)

        if not result.get("success", False):
            return []

        records = []
        for record_data in result.get("result", []):
            record = DNSRecord(
                id=record_data.get("id"),
                name=record_data.get("name"),
                type=RecordType(record_data.get("type")),
                content=record_data.get("content"),
                ttl=record_data.get("ttl", 60),
                proxied=record_data.get("proxied", False),
                priority=record_data.get("priority"),
                data=record_data.get("data"),
            )
            records.append(record)

        return records

    def create_dns_record(self, record: DNSRecord) -> bool:
        """Create a DNS record."""
        zone_id = self._ensure_zone_id(record.name)
        if not zone_id:
            print(
                f"Error: Could not find zone for domain {record.name}", file=sys.stderr
            )
            return False

        data = {
            "type": record.type.value,
            "name": record.name,
            "content": record.content,
            "ttl": record.ttl,
        }

        if record.type == RecordType.CNAME and hasattr(record, "proxied"):
            data["proxied"] = record.proxied

        if record.type == RecordType.TXT:
            data["content"] = f'"{record.content}"'

        if record.priority is not None:
            data["priority"] = record.priority

        print(f"Adding {record.type.value} record for {record.name}")
        result = self._make_request("POST", f"zones/{zone_id}/dns_records", data)

        return result.get("success", False)

    def delete_dns_record(self, record_id: str, domain: str) -> bool:
        """Delete a DNS record."""
        zone_id = self._ensure_zone_id(domain)
        if not zone_id:
            print(f"Error: Could not find zone for domain {domain}", file=sys.stderr)
            return False

        print(f"Deleting record ID: {record_id}")
        result = self._make_request(
            "DELETE", f"zones/{zone_id}/dns_records/{record_id}"
        )

        return result.get("success", False)

    def create_caa_record(self, caa_record: CAARecord) -> bool:
        """Create a CAA record."""
        zone_id = self._ensure_zone_id(caa_record.name)
        if not zone_id:
            print(
                f"Error: Could not find zone for domain {caa_record.name}",
                file=sys.stderr,
            )
            return False

        clean_value = caa_record.value.strip('"')

        data = {
            "type": "CAA",
            "name": caa_record.name,
            "ttl": caa_record.ttl,
            "data": {
                "flags": caa_record.flags,
                "tag": caa_record.tag,
                "value": clean_value,
            },
        }

        print(
            f"Adding CAA record for {caa_record.name} with tag {caa_record.tag} and value {clean_value}"
        )
        result = self._make_request("POST", f"zones/{zone_id}/dns_records", data)

        return result.get("success", False)
