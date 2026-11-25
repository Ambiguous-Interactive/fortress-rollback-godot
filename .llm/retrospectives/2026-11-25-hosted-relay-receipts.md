# Hosted relay receipts

| Finding | Evidence | Action |
| --- | --- | --- |
| The hosted workflow could run the stock room but could not collect exact server packet evidence. | The new dispatch control failed at the missing `inputs.relay_trace` binding. | Select the pinned trace server only for explicit relay cells. Keep its build receipt, scope and raw packet evidence in the job artifact. |
| Input validation after export can disappear behind a setup failure. | The first review found that the Web toolchain setup and exported match ran before the rejection step. | Validate the relay cell in the first job step. The shell control checks that invalid selections call neither build nor probe. |
| The presence of an archive does not bind it to the checkout. | The first local run reported `native archive runtime differs at addons/fortress_rollback/core/driver.gd`. | Reuse the previously verified archive only after the runner checks its current contents. |

`python3 -m unittest scripts.tests.test_workflow_tiers` reported
`Ran 17 tests` and `OK`. The dispatch control exercises both Godot pins,
three relay room sizes, the default path, invalid cells and a failed build.

The [browser integration guide](../skills/testing/references/browser-integration.md)
now places hosted trace validation before setup and requires the build
receipt with failure logs. The [migration guide](../../docs/native-backend-migration.md)
owns the manual dispatch command. Existing local trace and stock qualification
guidance still apply.

State `findings-acted`.
