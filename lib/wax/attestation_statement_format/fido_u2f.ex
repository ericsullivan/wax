defmodule Wax.AttestationStatementFormat.FIDOU2F do
  require Logger

  @moduledoc false

  @behaviour Wax.AttestationStatementFormat

  @impl Wax.AttestationStatementFormat
  def verify(att_stmt, auth_data, client_data_hash, verify_trust_root) do
    with :ok <- valid_cbor?(att_stmt),
         {:ok, pub_key} <- extract_and_verify_public_key(att_stmt),
         public_key_u2f <- get_raw_cose_key(auth_data),
         verification_data <- get_verification_data(auth_data, client_data_hash, public_key_u2f),
         :ok <- valid_signature?(att_stmt["sig"], verification_data, pub_key),
         :ok <-
           (if verify_trust_root, do: attestation_certificate_valid?(att_stmt["x5c"]), else: :ok)
    do
      {attestation_type, metadata_statement} = determine_attestation_type(att_stmt["x5c"])

      {:ok,
        {attestation_type,
          att_stmt["x5c"],
          metadata_statement
        }
      }
    else
      error ->
        error
    end
  end

  @spec valid_cbor?(Wax.Attestation.statement()) :: :ok | {:error, any()}
  defp valid_cbor?(att_stmt) do
    if is_binary(att_stmt["sig"])
    and is_list(att_stmt["x5c"])
    and length(Map.keys(att_stmt)) == 2 # only these two keys
    do
      :ok
    else
      {:error, :attestation_fidou2f_invalid_cbor}
    end
  end

  @spec extract_and_verify_public_key(Wax.Attestation.statement())
    :: {:ok, X509.PublicKey.t()} | {:error, any()}

  defp extract_and_verify_public_key(att_stmt) do
    case att_stmt["x5c"] do
      [der] ->
        cert = X509.Certificate.from_der!(der)

        pub_key = X509.Certificate.public_key(cert)

        Logger.debug("#{__MODULE__}: verifying validity of public key for certificate " <>
          "#{inspect(cert)}")

        if Wax.Utils.Certificate.signature_algorithm(cert) == {1, 2, 840, 113549, 1, 1, 11}
          and elem(pub_key, 1) == {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}} do
          {:ok, pub_key}
        else
          {:error, :attestation_fidou2f_invalid_public_key_algorithm}
        end

        _ ->
          {:error, :attestation_fidou2f_multiple_x5c}
    end
  end

  @spec get_raw_cose_key(Wax.AuthenticatorData.t()) :: binary()
  defp get_raw_cose_key(auth_data) do
    x = auth_data.attested_credential_data.credential_public_key[-2]
    y = auth_data.attested_credential_data.credential_public_key[-3]

    <<04>> <> x <> y
  end

  @spec get_verification_data(Wax.AuthenticatorData.t(), Wax.ClientData.hash(), binary())
    :: binary()
  defp get_verification_data(auth_data, client_data_hash, public_key_u2f) do
    <<0>>
    <> auth_data.rp_id_hash
    <> client_data_hash
    <> auth_data.attested_credential_data.credential_id
    <> public_key_u2f
  end

  @spec valid_signature?(binary(), binary(), X509.PublicKey.t()) :: :ok | {:error, any()}
  defp valid_signature?(sig, verification_data, pub_key) do
    Logger.debug("#{__MODULE__}: verifying signature #{inspect(sig)} " <>
      "of data #{inspect(verification_data)} " <>
      "with public key #{inspect(pub_key)}")

    if :public_key.verify(verification_data, :sha256, sig, pub_key) do
      :ok
    else
      {:error, :attestation_fidou2f_invalid_signature}
    end
  end

  @spec attestation_certificate_valid?([binary()]) :: :ok | {:error, any()}

  def attestation_certificate_valid?([leaf_cert | _]) do
    acki = Wax.Utils.Certificate.attestation_certificate_key_identifier(leaf_cert)

    case Wax.Metadata.get_by_acki(acki) do
      %Wax.MetadataStatement{} ->
        :ok

      nil ->
        {:error, :attestation_fidou2f_root_trust_certificate_not_found}
    end
  end

  @spec determine_attestation_type([binary()])
    :: {Wax.Attestation.type(), Wax.MetadataStatement.t() | nil}

  defp determine_attestation_type([leaf_cert | _]) do
    acki = Wax.Utils.Certificate.attestation_certificate_key_identifier(leaf_cert)

    Logger.debug("#{__MODULE__}: determining attestation type for acki=#{inspect(acki)}")

    case Wax.Metadata.get_by_acki(acki) do
      nil ->
        {:uncertain, nil}

      #FIXME: here we assume that :basic and :attca are exclusive for a given authenticator
      # but this seems however unspecified
      metadata_statement ->
        if :tag_attestation_basic_full in metadata_statement.attestation_types do
          {:basic, metadata_statement}
        else
          if :tag_attestation_attca in metadata_statement.attestation_types do
            {:attca, metadata_statement}
          else
            {:uncertain, nil}
          end
        end
    end
  end
end
