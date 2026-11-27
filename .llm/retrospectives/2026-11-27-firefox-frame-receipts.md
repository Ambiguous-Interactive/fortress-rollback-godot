# Firefox frame receipts

| Finding | Evidence | Action |
| --- | --- | --- |
| The debugger preserves Gecko's receive timestamp. | The real Firefox control measured 567.071 ms between receipt of the exact carrier and the page handler's matching acknowledgement. The public Playwright callback exposes the bytes. | Fingerprint the pinned Playwright core and retain only bounded carrier digests with both clock domains. |
| The tagged proxy endpoint must also be the page's actual game endpoint. | The first review found the connection call was using the untagged upstream URL because the observer's local endpoint was out of scope. | Use one resolver for game dispatch and debugger binding. Check the exact socket and frozen recipient in the live room. |
| Queuing a stderr write can leave the original receipt pending during cleanup. | Adding a write acknowledgement exposed a second path. A closed stderr pipe stopped the fixture before its cleanup log was created. The same entrypoint fixture now completes context, browser and server cleanup with the read end closed. | Handle the stream error and callback. Emit a supplemental receipt only after the original write was acknowledged. |
| A fake Firefox launch inherited the local executable setting. | Hosted Gate 45941362930 failed at `missing executable for firefox` instead of the fixture's intended `PRIMARY_FAILURE`. Removing the inherited variable reproduced it locally. | Set the fake executable in the fixture and repeat with the parent variable removed. |

The [browser integration guidance](../skills/testing/references/browser-integration.md)
now specifies the write acknowledgement, bounded wait, debugger clocks and
fake browser setup. It replaces the earlier instruction that only named publication.

State `findings-acted`.
