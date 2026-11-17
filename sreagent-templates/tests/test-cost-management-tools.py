import json
import os
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import requests
import yaml

ROOT = Path(__file__).resolve().parents[1] / "recipes/cost-management/config/tools"
SUB = os.environ.get("AZURE_SUBSCRIPTION_ID")
if not SUB:
    sys.exit("Set AZURE_SUBSCRIPTION_ID before you run this test.")

identity = types.ModuleType("azure.identity")
class DefaultAzureCredential:
    def get_token(self, _scope):
        return types.SimpleNamespace(token="test-token")
identity.DefaultAzureCredential = DefaultAzureCredential
sys.modules["azure.identity"] = identity

def load(name):
    source = yaml.safe_load((ROOT / (name + ".yaml")).read_text())["spec"]["functionCode"]
    namespace = {}
    exec(compile(source, name, "exec"), namespace)
    return namespace["main"]

class Response:
    def __init__(self, value=None, status=200):
        self.value = value or {}
        self.status_code = status
        self.text = json.dumps(self.value)
        self.reason = "error" if status >= 400 else "OK"
    def json(self):
        return self.value
    def raise_for_status(self):
        if self.status_code >= 400:
            raise requests.HTTPError(str(self.status_code), response=self)

def result(main, **kwargs):
    value = main(**kwargs)
    return json.loads(value) if isinstance(value, str) else value

class ToolTests(unittest.TestCase):
    def test_capacity_detail_failure_never_reports_zero(self):
        def get(url, **_):
            if "/capacityReservations/" in url:
                return Response(status=500)
            if "/capacityReservations?" in url:
                return Response({"value": [{"id": "/reservations/r", "name": "r"}]})
            if "/reservations/r?" in url:
                return Response(status=500)
            if "/capacityReservationGroups?" in url:
                return Response({"value": [{"name": "g", "id": "/groups/g"}]})
            return Response({"properties": {"virtualMachinesAssociated": []}})
        with patch.object(requests, "get", side_effect=get):
            group = result(load("capacity-reservation-groups"), subscription_id=SUB)["groups"][0]
        self.assertEqual(group["reservations"], [])
        self.assertIn("detail_error", group)

    def test_zone_single_and_unregistered_peer(self):
        locations = Response({"value": [{"name": "eastus2", "availabilityZoneMappings": [{"logicalZone": "1", "physicalZone": "eastus2-az1"}]}]})
        with patch.object(requests, "get", return_value=locations), patch.object(requests, "post", return_value=Response({"error": {"code": "InvalidResourceType"}}, 400)):
            main = load("zone-mapping")
            single = result(main, subscription_id=SUB, location="eastus2", peer_subscription_ids=SUB)
            other = result(main, subscription_id=SUB, location="eastus2", peer_subscription_ids="00000000-0000-0000-0000-000000000001")
        self.assertEqual(single["subscription_zone_mappings"]["eastus2"]["1"], "eastus2-az1")
        self.assertEqual(single["cross_subscription_peer_comparison"]["status"], "not_applicable_single_subscription")
        self.assertEqual(other["cross_subscription_peer_comparison"]["status"], "feature_not_registered_used_locations_api")

    def test_vm_thresholds_and_omissions(self):
        usages = [{"name": {"localizedValue": name}, "currentValue": current, "limit": 100}
                  for name, current in [("Standard D Family vCPUs", 80), ("Standard E Family vCPUs", 95), ("Other", 0)]]
        with patch.object(requests, "get", return_value=Response({"value": usages})):
            value = result(load("vm-quota-usage"), subscription_id=SUB, location="eastus2")
        self.assertEqual(value["summary"]["warning_count_ge_80pct"], 2)
        self.assertEqual(value["summary"]["critical_count_ge_95pct"], 1)
        self.assertEqual(value["summary"]["zero_usage_omitted_count"], 1)

    def test_vm_paginates_many_active_families(self):
        usages = [{"name": {"localizedValue": f"Standard D{i} Family vCPUs"},
                   "currentValue": 1, "limit": 100} for i in range(100)]
        with patch.object(requests, "get", return_value=Response({"value": usages})):
            main = load("vm-quota-usage")
            first = result(main, subscription_id=SUB, location="eastus2")
            second = result(main, subscription_id=SUB, location="eastus2", offset=first["next_offset"])
        self.assertLess(len(json.dumps(first, separators=(",", ":"))), 900)
        self.assertNotEqual(first["quotas"][0], second["quotas"][0])

    def test_cosmos_failed_page_is_unknown_and_5xx_not_missing_region(self):
        def get(url, **_):
            if "/subscriptions/" in url and "/providers/" not in url:
                return Response({"value": [{"name": "eastus2"}]})
            if "DocumentDB/locations" in url:
                return Response({"error": "upstream"}, 503)
            if "DocumentDB/databaseAccounts" in url:
                return Response({"value": [{"name": "partial"}], "nextLink": "https://management.azure.com/next"})
            if url.endswith("/next"):
                return Response({"error": "failed page"}, 500)
            raise AssertionError(url)
        with patch.object(requests, "get", side_effect=get):
            value = result(load("db-service-quotas"), subscription_id=SUB, location="eastus2", services="COSMOSDB")
        self.assertEqual(value["quotas"][0]["limit"], 250)
        self.assertEqual(value["quotas"][0]["flag"], "unknown_read_error")
        self.assertIsNone(value["quotas"][0]["current_value"])
        self.assertIsNone(value["quotas"][0]["utilization_pct"])
        self.assertIn("upstream_5xx", [error["kind"] for error in value["errors"]])
        self.assertNotIn("service_not_in_region", [error["kind"] for error in value["errors"]])

    def test_graph_subscription_and_result_pagination(self):
        gets = [Response({"value": [{"subscriptionId": SUB}], "nextLink": "https://management.azure.com/next"}), Response({"value": [{"subscriptionId": "two"}]})]
        posts = [Response({"data": [{"n": 1}], "$skipToken": "next", "totalRecords": 2}), Response({"data": [{"n": 2}], "totalRecords": 2})]
        with patch.object(requests, "get", side_effect=gets), patch.object(requests, "post", side_effect=posts) as post:
            value = result(load("resource-graph-query"), query="Resources")
        self.assertEqual(value["count"], 2)
        self.assertEqual(value["subscriptions"], [SUB, "two"])
        self.assertEqual(post.call_args_list[1].kwargs["json"]["options"]["$skipToken"], "next")

    def test_billing_403_falls_back_to_subscription(self):
        with patch.object(requests, "get", side_effect=[Response(status=403), Response({"value": []})]):
            value = result(load("benefit-recommendations"), subscription_id=SUB, billing_scope="/providers/Microsoft.Billing/billingAccounts/123")
        self.assertEqual(value["scope_used"], "/subscriptions/" + SUB)
        self.assertIn("denied", value["billing_scope_fallback_reason"])
        self.assertNotIn("error", value)

    def test_billing_denial_discovers_enabled_subscription(self):
        responses = [
            Response(status=403),
            Response({"value": [{"state": "Disabled", "subscriptionId": "disabled"}],
                      "nextLink": "https://management.azure.com/next"}),
            Response({"value": [{"state": "Enabled", "subscriptionId": SUB}]}),
            Response({"value": []}),
        ]
        with patch.object(requests, "get", side_effect=responses) as get:
            value = result(load("benefit-recommendations"), subscription_id="", billing_scope="/providers/Microsoft.Billing/billingAccounts/123")
        self.assertEqual(value["scope_used"], "/subscriptions/" + SUB)
        self.assertIn("/subscriptions?api-version=2022-12-01", get.call_args_list[1].args[0])
        self.assertNotIn("error", value)

    def test_benefit_maps_arm_fields_without_treating_id_as_sku(self):
        recommendation = {"name": "opaque-id", "properties": {
            "armSkuName": "Compute_Savings_Plan", "scope": "Shared", "term": "P1Y",
            "commitmentGranularity": "Hourly", "totalHours": 707,
            "recommendationDetails": {"commitmentAmount": 10.828, "savingsAmount": 3286.959,
                                      "averageUtilizationPercentage": 99.628, "coveragePercentage": 80.683}}}
        with patch.object(requests, "get", return_value=Response({"value": [recommendation]})):
            value = result(load("benefit-recommendations"), subscription_id=SUB, lookback_period="Last30Days")
        row = value["recommendations"][0]
        self.assertEqual(row["sku"], "Compute_Savings_Plan")
        self.assertEqual(row["commit_hr"], 10.828)
        self.assertEqual(row["savings_30d"], 3286.959)
        self.assertEqual(row["util_pct"], 99.628)
        self.assertEqual(row["hours"], 707)

    def test_graph_invalid_query_falls_back_and_limits_output(self):
        bad = Response({"error": {"code": "InvalidQuery", "message": "invalid column"}}, 400)
        rows = [{"name": "a" * 150, "type": "x"} for _ in range(20)]
        with patch.object(requests, "post", side_effect=[bad, Response({"data": rows, "totalRecords": 20})]) as post:
            value = result(load("resource-graph-query"), query="Resources | project missing", subscription_ids=SUB)
        self.assertTrue(value["kql_fallback_applied"])
        self.assertIn("invalid column", value["original_kql_error"])
        self.assertEqual(value["row_count"], 20)
        self.assertTrue(value["truncated_for_telemetry_limit"])
        self.assertLess(len(json.dumps(value, separators=(",", ":"))), 900)
        self.assertIn("sku.name, tags | limit 100", post.call_args_list[1].kwargs["json"]["query"])

    def test_graph_non_query_bad_request_not_masked(self):
        with patch.object(requests, "post", return_value=Response({"error": {"code": "BadRequest", "message": "invalid subscription"}}, 400)):
            value = result(load("resource-graph-query"), query="Resources", subscription_ids=SUB)
        self.assertTrue(value["errors"])
        self.assertNotIn("kql_fallback_applied", value)

    def test_noncompute_thresholds(self):
        def get(url, **_):
            if "Microsoft.Storage" in url:
                return Response({"value": [{"name": {"localizedValue": "Storage Accounts"}, "currentValue": 80, "limit": 100}]})
            return Response({"value": [{"name": {"localizedValue": "Virtual Networks"}, "currentValue": 95, "limit": 100}]})
        with patch.object(requests, "get", side_effect=get), patch.object(requests, "post", return_value=Response({"data": []})):
            value = result(load("non-compute-quotas"), subscription_id=SUB, location="eastus2")
        self.assertEqual(value["summary"]["warning_count_ge_80pct"], 2)
        self.assertEqual(value["summary"]["critical_count_ge_95pct"], 1)

    def test_sku_capabilities_and_summary(self):
        sku = {"name": "Standard_D2s_v5", "family": "D", "capabilities": [{"name": "vCPUs", "value": "2"}, {"name": "MemoryGB", "value": "8"}], "locationInfo": [{"location": "eastus2", "zones": ["1"]}]}
        with patch.object(requests, "get", return_value=Response({"value": [sku]})):
            value = result(load("sku-availability"), subscription_id=SUB, location="eastus2")
        self.assertEqual(value["summary"]["unrestricted_count"], 1)
        self.assertEqual(value["unrestricted_skus"][0]["vcpus"], "2")

    def test_sku_large_results_have_continuation(self):
        skus = [{"name": f"Standard_D{i}", "family": "D", "capabilities": []} for i in range(150)]
        main = load("sku-availability")
        with patch.object(requests, "get", return_value=Response({"value": skus})):
            first = result(main, subscription_id=SUB, location="eastus2")
            second = result(main, subscription_id=SUB, location="eastus2", offset=first["pagination"]["next_offset"])
        self.assertLess(len(json.dumps(first, separators=(",", ":"))), 900)
        self.assertGreater(first["pagination"]["next_offset"], 0)
        self.assertEqual(second["unrestricted_skus"][0]["sku"], skus[first["pagination"]["next_offset"]]["name"])

if __name__ == "__main__":
    unittest.main()
