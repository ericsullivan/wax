defmodule Wax.AttestationStatementFormat.AndroidSafetynet do
  require Logger

  @moduledoc false

  @behaviour Wax.AttestationStatementFormat

  # GSR2 root certificate
  @root_cert """
  -----BEGIN CERTIFICATE-----
  MIIDujCCAqKgAwIBAgILBAAAAAABD4Ym5g0wDQYJKoZIhvcNAQEFBQAwTDEgMB4G
  A1UECxMXR2xvYmFsU2lnbiBSb290IENBIC0gUjIxEzARBgNVBAoTCkdsb2JhbFNp
  Z24xEzARBgNVBAMTCkdsb2JhbFNpZ24wHhcNMDYxMjE1MDgwMDAwWhcNMjExMjE1
  MDgwMDAwWjBMMSAwHgYDVQQLExdHbG9iYWxTaWduIFJvb3QgQ0EgLSBSMjETMBEG
  A1UEChMKR2xvYmFsU2lnbjETMBEGA1UEAxMKR2xvYmFsU2lnbjCCASIwDQYJKoZI
  hvcNAQEBBQADggEPADCCAQoCggEBAKbPJA6+Lm8omUVCxKs+IVSbC9N/hHD6ErPL
  v4dfxn+G07IwXNb9rfF73OX4YJYJkhD10FPe+3t+c4isUoh7SqbKSaZeqKeMWhG8
  eoLrvozps6yWJQeXSpkqBy+0Hne/ig+1AnwblrjFuTosvNYSuetZfeLQBoZfXklq
  tTleiDTsvHgMCJiEbKjNS7SgfQx5TfC4LcshytVsW33hoCmEofnTlEnLJGKRILzd
  C9XZzPnqJworc5HGnRusyMvo4KD0L5CLTfuwNhv2GXqF4G3yYROIXJ/gkwpRl4pa
  zq+r1feqCapgvdzZX99yqWATXgAByUr6P6TqBwMhAo6CygPCm48CAwEAAaOBnDCB
  mTAOBgNVHQ8BAf8EBAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUm+IH
  V2ccHsBqBt5ZtJot39wZhi4wNgYDVR0fBC8wLTAroCmgJ4YlaHR0cDovL2NybC5n
  bG9iYWxzaWduLm5ldC9yb290LXIyLmNybDAfBgNVHSMEGDAWgBSb4gdXZxwewGoG
  3lm0mi3f3BmGLjANBgkqhkiG9w0BAQUFAAOCAQEAmYFThxxol4aR7OBKuEQLq4Gs
  J0/WwbgcQ3izDJr86iw8bmEbTUsp9Z8FHSbBuOmDAGJFtqkIk7mpM0sYmsL4h4hO
  291xNBrBVNpGP+DTKqttVCL1OmLNIG+6KYnX3ZHu01yiPqFbQfXf5WRDLenVOavS
  ot+3i9DAgBkcRcAtjOj4LaR0VknFBbVPFd5uRHg5h6h+u/N5GJG79G+dwfCMNYxd
  AfvDbbnvRG15RjF+Cv6pgsH/76tuIMRQyV+dTZsXjAzlAcmgQWpzU/qlULRuJQ/7
  TBj0/VLZjmmx6BEP3ojY+x1J96relc8geMJgEtslQIxq/H5COEBkEveegeGTLg==
  -----END CERTIFICATE-----
  """
  |> X509.Certificate.from_pem!()
  |> X509.Certificate.to_der()

  @impl Wax.AttestationStatementFormat
  def verify(att_stmt, auth_data, client_data_hash, _verify_trust_root) do
    try do
      [header_b64, payload_b64, _sig] = String.split(att_stmt["response"], ".")

      payload =
        payload_b64
        |> Base.url_decode64!(padding: false)
        |> Jason.decode!()

      header =
        header_b64
        |> Base.url_decode64!(padding: false)
        |> Jason.decode!()

      with :ok <- valid_cbor?(att_stmt),
           :ok <- valid_safetynet_response?(payload, att_stmt["ver"]),
           :ok <- nonce_valid?(auth_data, client_data_hash, payload),
           :ok <- valid_cert_hostname?(header),
           :ok <- Wax.Utils.JWS.verify(att_stmt["response"], @root_cert)
    do
        leaf_cert =
          header["x5c"]
          |> List.first()
          |> Base.decode64!()

        {:ok, {:basic, leaf_cert, nil}}
      else
        error ->
          error
      end
    rescue
      _ ->
        {:error, :attestation_safetynet_invalid_att_stmt}
    end
  end

  @spec valid_cbor?(Wax.Attestation.statement()) :: :ok | {:error, any()}
  defp valid_cbor?(att_stmt) do
    if is_binary(att_stmt["ver"])
    and is_binary(att_stmt["response"])
    and length(Map.keys(att_stmt)) == 2 # only these two keys
    do
      :ok
    else
      {:error, :attestation_safetynet_invalid_cbor}
    end
  end

  @spec valid_safetynet_response?(map() | Keyword.t() | nil, String.t()) :: :ok | {:error, any()}

  defp valid_safetynet_response?(%{} = safetynet_response, _version) do
    #FIXME: currently unimplementable? see:
    # https://github.com/w3c/webauthn/issues/968
    # besides the spec seems to have an error with the `ctsProfileMatch` (`true` then `true`):
    # https://developer.android.com/training/safetynet/attestation#compat-check-response
    #
    # Therefore for now we just check `ctsProfileMatch`
    Logger.debug("#{__MODULE__}: verifying SafetyNet response validity: " <>
      "#{inspect(safetynet_response)}")

    if safetynet_response["ctsProfileMatch"] == true do
      :ok
    else
      {:error, :attestation_safetynet_invalid_ctsProfileMatch}
    end
  end

  defp valid_safetynet_response?(_, _), do: {:error, :attestation_safetyney_invalid_payload}

  @spec nonce_valid?(Wax.AuthenticatorData.t(), binary(), map())
    :: :ok | {:error, any()}

  defp nonce_valid?(auth_data, client_data_hash, payload) do
    expected_nonce =
      Base.encode64(:crypto.hash(:sha256, auth_data.raw_bytes <> client_data_hash))

    if payload["nonce"] == expected_nonce do
      :ok
    else
      {:error, :attestation_safetynet_invalid_nonce}
    end
  end

  @spec valid_cert_hostname?(map()) :: :ok | {:error, any()}
  defp valid_cert_hostname?(header) do
    leaf_cert =
      header["x5c"]
      |> List.first()
      |> Base.decode64!()
      |> X509.Certificate.from_der!()

    Logger.debug("#{__MODULE__}: verifying certificate: #{inspect(leaf_cert)}")

    #FIXME: verify it's indeed the SAN that must be checked
    # since spec says `hostname` (couldn't it be the CN?, both?)
    case X509.Certificate.extension(leaf_cert, :subject_alt_name) do
      {:Extension, {2, 5, 29, 17}, false, [dNSName: 'attest.android.com']} ->
        :ok

      _ ->
        {:error, :attestation_safetynet_invalid_hostname}
    end
  end
end
