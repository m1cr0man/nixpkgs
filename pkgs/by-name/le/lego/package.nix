{ lib, fetchFromGitHub, buildGoModule, nixosTests }:

buildGoModule rec {
  pname = "lego";
  version = "4.20.4";

  src = fetchFromGitHub {
    owner = "m1cr0man";
    repo = pname;
    rev = "renew-rc-2";
    hash = "sha256-XsuEllRaFGCWmMMs9VOFNBRw6KrzhSdJmAkXds2L1SE=";
  };

  vendorHash = "sha256-r9R+d5H5RjwzksbAlcFPyRtCGXSH1JBVfNHr5QiHA7Y=";

  doCheck = false;

  subPackages = [ "cmd/lego" ];

  ldflags = [
    "-s" "-w" "-X main.version=${version}"
  ];

  meta = with lib; {
    description = "Let's Encrypt client and ACME library written in Go";
    license = licenses.mit;
    homepage = "https://go-acme.github.io/lego/";
    maintainers = teams.acme.members;
    mainProgram = "lego";
  };

  passthru.tests.lego = nixosTests.acme;
}
