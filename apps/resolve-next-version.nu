#!/usr/bin/env nu

def main [
  --format: string,
  --name: string,
  --upstream: string,
  --base-url: string = "http://pkg.mecha.so"
] {

  if $format not-in ["deb", "rpm"] {
    error make { msg: "format must be 'deb' or 'rpm'" }
  }

  # Read username/password from env correctly in Nushell
  let username = ($env.MECHA_PULP_USERNAME? | default "")
  let password = ($env.MECHA_PULP_PASSWORD? | default "")

  let endpoint = if $format == "deb" {
    $"($base_url)/pulp/api/v3/content/deb/packages/?package=($name)"
  } else {
    $"($base_url)/pulp/api/v3/content/rpm/packages/?name=($name)"
  }

  print $"[INFO] Querying Pulp: ($endpoint)"

  let headers = if ($username != "" and $password != "") {
    {
      Authorization: (
        "Basic " + (
          $"($username):($password)" | encode base64
        )
      )
      Accept: "application/json"
    }
  } else {
    { Accept: "application/json" }
  }

  let response = (http get --headers $headers $endpoint)
  let results = ($response.results? | default [])

  if ($results | is-empty) {
    print $"($upstream)-1"
    return
  }

  let versions = (
    $results
    | each { |pkg|
        if $format == "deb" { $pkg.version } else { $"($pkg.version)-($pkg.release)" }
      }
  )

  let revisions = (
    $versions
    | where { |v| $v | str starts-with $"($upstream)-" }
    | each { |v| ($v | split row "-" | last | into int) }
  )

  if ($revisions | is-empty) {
    print $"($upstream)-1"
    return
  }

  let max_rev = ($revisions | math max)
  let next_rev = $max_rev + 1
  let next_version = $"($upstream)-($next_rev)"
  print $next_version
}
