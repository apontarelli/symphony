defmodule SymphonyElixir.HandoffRoute.AutoLandPolicyTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.HandoffRoute.AutoLandPolicy

  test "strict production policy requires rollback plan evidence instead of generic recovery" do
    result =
      AutoLandPolicy.evaluate(%{
        checks: auto_land_checks(~w(recovery deployment_status monitoring_source incident_issue_creation)),
        labels: [],
        policy: %{
          project: %{criticality: "prototype", deployment_coupling: "production_web"},
          auto_land: %{dry_run: true}
        }
      })

    assert result.enabled?
    assert result.missing_checks == ["rollback_plan"]

    assert Enum.any?(
             result.evidence,
             &(&1.kind == :auto_land and &1.status == :missing and &1.summary =~ "rollback_plan")
           )
  end

  test "strict production policy passes when all recovery ownership evidence is present" do
    result =
      AutoLandPolicy.evaluate(%{
        checks: auto_land_checks(strict_recovery_checks()),
        labels: [],
        policy: %{
          project: %{criticality: "prototype", deployment_coupling: "production_web"},
          auto_land: %{dry_run: true}
        }
      })

    assert result.missing_checks == []

    assert Enum.any?(
             result.evidence,
             &(&1.kind == :auto_land and &1.status == :passed and &1.summary =~ "rollback_plan")
           )
  end

  test "strict auto-land posture accepts rollback-plan alias as rollback plan proof" do
    result =
      AutoLandPolicy.evaluate(%{
        checks: auto_land_checks(~w(deployment_status rollback-plan monitoring_source incident_issue_creation)),
        labels: [],
        policy: %{
          project: %{criticality: "prototype", deployment_coupling: "none"},
          auto_land: %{posture: "strict", dry_run: true}
        }
      })

    assert result.missing_checks == []
  end

  test "custom required checks tolerate malformed direct classifier metadata" do
    result =
      AutoLandPolicy.evaluate(%{
        checks: auto_land_checks([]),
        labels: [],
        policy: %{
          project: %{criticality: "prototype", deployment_coupling: "none"},
          auto_land: %{
            posture: "permissive",
            required_checks: "security-review",
            dry_run: true
          }
        }
      })

    assert result.missing_checks == []
    refute Enum.any?(result.evidence, &(&1.summary =~ "security-review"))
  end

  test "force-human-review labels produce policy evidence" do
    result =
      AutoLandPolicy.evaluate(%{
        checks: auto_land_checks([]),
        labels: ["manual-review"],
        policy: %{
          project: %{criticality: "prototype", deployment_coupling: "none"},
          auto_land: %{posture: "permissive", dry_run: true}
        }
      })

    assert result.matched_force_human_review_label == "manual-review"
    assert Enum.any?(result.evidence, &(&1.kind == :policy and &1.summary =~ "manual-review"))
  end

  test "normalizes string-keyed policy and blank check metadata defensively" do
    result =
      AutoLandPolicy.evaluate(%{
        checks:
          [
            %{name: nil, status: :passed},
            %{name: " ", status: :passed},
            %{status: :passed}
          ] ++ auto_land_checks(~w(rollback-plan deployment_status monitoring_source incident_issue_creation)),
        labels: [nil, " Manual-Review "],
        policy: %{
          123 => "ignored",
          "project" => %{"deployment_coupling" => "production_web"},
          "auto-land" => %{"dry_run" => true}
        }
      })

    assert result.matched_force_human_review_label == "manual-review"
    assert "rollback_plan" in result.required_checks
    assert result.missing_checks == []
  end

  test "malformed policy input evaluates to inert defaults" do
    result = AutoLandPolicy.evaluate("not a policy context")

    refute result.enabled?
    assert result.required_checks == []
    assert result.missing_checks == []
    assert result.evidence == []
  end

  test "malformed labels are ignored" do
    result =
      AutoLandPolicy.evaluate(%{
        checks: auto_land_checks([]),
        labels: "not a list",
        policy: %{
          project: %{criticality: "prototype", deployment_coupling: "none"},
          auto_land: %{posture: "permissive", dry_run: true}
        }
      })

    assert result.matched_force_human_review_label == nil
    assert result.missing_checks == []
  end

  defp auto_land_checks(extra_checks) do
    ~w(tests quality_gates automated_review route_classification sync)
    |> Kernel.++(extra_checks)
    |> Enum.map(&%{name: &1, status: :passed})
  end

  defp strict_recovery_checks do
    ~w(deployment_status rollback_plan monitoring_source incident_issue_creation)
  end
end
