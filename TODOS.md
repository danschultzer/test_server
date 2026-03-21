# TODOS

## SMTP: Per-command handlers (`on_mail_from`, `on_rcpt_to`, `on_data`)

**Added:** 2026-03-21
**Priority:** Low
**Depends on:** Core SMTP implementation

Add fine-grained per-command handlers that fire at each SMTP command, not just at DATA completion. Enables testing edge cases like rejecting specific recipients at RCPT TO time or simulating slow MAIL FROM responses.

The simple `fn email, state -> response` handler covers 90% of use cases. Per-command handlers are a power-user feature for the remaining 10%.

**Why deferred:** Adds API surface area and complicates the session state machine. Most tests don't need this level of control.

## Shared handler dispatch module

**Added:** 2026-03-21
**Priority:** Low
**Triggered by:** Third protocol addition

Extract `TestServer.HandlerDispatch` with shared FIFO handler logic (dispatch, match, format, error reporting) used by SSH.Instance, SMTP.Instance, and future protocol instances.

Currently ~40 lines of structurally similar code in each Instance module. Rule of three — refactor when a third protocol is added.

**Why deferred:** SSH and SMTP dispatch have meaningful structural differences (SSH has channel_ref scoping and state threading across messages; SMTP has flat email dispatch). Abstracting now risks a leaky abstraction for marginal benefit.
