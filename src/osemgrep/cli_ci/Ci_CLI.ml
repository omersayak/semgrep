module OutJ = Semgrep_output_v1_t
module Arg = Cmdliner.Arg
module Cmd = Cmdliner.Cmd
module Term = Cmdliner.Term
module H = Cmdliner_

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(*
   'semgrep ci' command-line parsing.

   Translated from ci.py
*)

(*****************************************************************************)
(* Types and constants *)
(*****************************************************************************)

(* TODO: we should redesign the CLI flags of semgrep ci and reduce
 * them to the minimum; if you want flexibility, use semgrep scan,
 * otherwise semgrep ci should be minimalist and take no
 * args at all in most cases.
 * We probably still want though conf_runner flags like:
 *  - --max-memory, -j, --timeout (even though iago want to remove it)
 *  - the pro-engine flags --pro, --oss-only, etc (even though again
 *    we're going towards remove --pro for more precise --interfile,
 *    --secrets, etc)
 *  - --include, --exclude
 *  - maybe also --output? (even though I don't understand why people
 *    just don't simply use shell redirection)
 *)
type conf = {
  (* TODO? is this still used? *)
  audit_on : string list;
  dry_run : bool;
  suppress_errors : bool;
  (* --code/--sca/--secrets/ *)
  products : OutJ.product list;
  (* 'semgrep ci' shares most of its flags with 'semgrep scan' *)
  scan_conf : Scan_CLI.conf;
}
[@@deriving show]

(*************************************************************************)
(* Command-line flags *)
(*************************************************************************)

let o_audit_on : string list Term.t =
  let info = Arg.info [ "audit-on" ] ~env:(Cmd.Env.info "SEMGREP_AUDIT_ON") in
  Arg.value (Arg.opt_all Arg.string [] info)

(* ugly: we also have a --dryrun in semgrep scan *)
let o_dry_run : bool Term.t =
  let info =
    Arg.info [ "dry-run" ]
      ~doc:
        {|When set, will not start a scan on semgrep.dev and will not report
findings. Instead will print out json objects it would have sent.|}
  in
  Arg.value (Arg.flag info)

let o_internal_ci_scan_results : bool Term.t =
  let info =
    Arg.info [ "internal-ci-scan-results" ] ~doc:{|<internal, do not use>|}
  in
  Arg.value (Arg.flag info)

let o_supply_chain : bool Term.t =
  let info =
    Arg.info [ "supply-chain" ] ~doc:{|Run Semgrep Supply Chain product.|}
  in
  Arg.value (Arg.flag info)

let o_code : bool Term.t =
  let info = Arg.info [ "code" ] ~doc:{|Run Semgrep Code (SAST) product.|} in
  Arg.value (Arg.flag info)

let o_beta_testing_secrets : bool Term.t =
  let info =
    Arg.info [ "beta-testing-secrets" ]
      ~doc:{|Please use --secrets instead of --beta-testing-secrets.|}
  in
  Arg.value (Arg.flag info)

let o_secrets : bool Term.t =
  let info =
    Arg.info [ "secrets" ]
      ~doc:
        {|Run Semgrep Secrets product, including support for secret validation.
          Requires access to Secrets, contact support@semgrep.com for more
          information.|}
  in
  Arg.value (Arg.flag info)

let o_suppress_errors : bool Term.t =
  H.negatable_flag_with_env [ "suppress-errors" ]
    ~neg_options:[ "no-suppress-errors" ]
    ~env:(Cmd.Env.info "SEMGREP_SUPPRESS_ERRORS")
    ~default:true
    ~doc:
      {|Configures how the CI command reacts when an error occurs.
If true, encountered errors are suppressed and the exit code is zero (success).
If false, encountered errors are not suppressed and the exit code is non-zero
(failure).|}

(*************************************************************************)
(* Turn argv into conf *)
(*************************************************************************)

let cmdline_term : conf Term.t =
  (* Note that we ignore the _xxx_meta; The actual environment variables
   * grabbing is done in Ci_subcommand.generate_meta_from_env, but we pass
   * it below so we can get a nice man page documenting those environment
   * variables (Romain's idea).
   *)
  let combine scan_conf audit_on beta_testing_secrets code dry_run
      _internal_ci_scan_results secrets supply_chain suppress_errors _git_meta
      _github_meta =
    let products =
      (if beta_testing_secrets || secrets then [ `Secrets ] else [])
      @ (if code then [ `SAST ] else [])
      @ if supply_chain then [ `SCA ] else []
    in
    { scan_conf; audit_on; dry_run; suppress_errors; products }
  in
  Term.(
    const combine
    $ Scan_CLI.cmdline_term ~allow_empty_config:true
    $ o_audit_on $ o_beta_testing_secrets $ o_code $ o_dry_run
    $ o_internal_ci_scan_results $ o_secrets $ o_supply_chain
    $ o_suppress_errors $ Git_metadata.env $ Github_metadata.env)

let doc = "the recommended way to run semgrep in CI"

let man : Cmdliner.Manpage.block list =
  [
    `S Cmdliner.Manpage.s_description;
    `P
      "In pull_request/merge_request (PR/MR) contexts, `semgrep ci` will only \
       report findings that were introduced by the PR/MR.";
    `P
      "When logged in, `semgrep ci` runs rules configured on Semgrep App and \
       sends findings to your findings dashboard.";
    `P "Only displays findings that were marked as blocking.";
  ]
  @ CLI_common.help_page_bottom

let cmdline_info : Cmd.info = Cmd.info "semgrep ci" ~doc ~man

(*****************************************************************************)
(* Entry point *)
(*****************************************************************************)

let parse_argv (argv : string array) : conf =
  (* mostly a copy of Scan_CLI.parse_argv with different doc and man *)
  let cmd : conf Cmd.t = Cmd.v cmdline_info cmdline_term in
  CLI_common.eval_value ~argv cmd
