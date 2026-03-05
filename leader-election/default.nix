{
  lib,
  buildGoModule,
}:
buildGoModule {
  pname = "headscale-leader-election";
  version = "0.1.0";

  src = ./.;

  # Update this hash after any change to go.mod/go.sum:
  #   nix build .#headscale-leader-election 2>&1 | grep "got:"
  vendorHash = null; # stdlib-only, no external deps
  env = {
    CGO_ENABLED = 0;
  };
  ldflags = [
    "-s"
    "-w"
    "-extldflags=-static"
  ];

  meta = with lib; {
    description = "Priority-based leader election daemon for headscale HA (no external coordinator required)";
    license = licenses.mit;
    mainProgram = "leader-election";
  };
}
