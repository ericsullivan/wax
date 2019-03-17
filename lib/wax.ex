defmodule Wax do
  require Logger

  @moduledoc """
  Functions for FIDO2 registration and authentication

  ## Options
  The options are set when generating the challenge (for both registration and
  authentication). Options can be configured either globally in the configuration
  file or when generating the challenge. Some also have default values.

  Option values set during challenge generation take precedence over globally configured
  options, which takes precedence over default values.

  These options are:

  |  Option       |  Type         |  Applies to       |  Default value                | Notes |
  |:-------------:|:-------------:|-------------------|:-----------------------------:|-------|
  |`origin`|`String.t()`|<ul style="margin:0"><li>registration</li><li>authentication</li></ul>| | Mandatory. Example: `https://www.example.com` |
  |`rp_id`|`String.t()` or `:auto`|<ul style="margin:0"><li>registration</li><li>authentication</li></ul>|If set to `:auto`, automatically determined from the `origin` (set to the host) | With `:auto`, it defaults to the full host (e.g.: `www.example.com`). This option allow you to set the `rp_id` to another valid value (e.g.: `example.com`) |
  |`user_verified_required`|`boolean()`|<ul style="margin:0"><li>registration</li><li>authentication</li></ul>| `false`| |
  |`trusted_attestation_types`|`[Wax.Attestation.type()]`|<ul style="margin:0"><li>registration</li></ul>|`[:none, :basic, :uncertain, :attca, :self]`| |
  |`verify_trust_root`|`boolean()`|<ul style="margin:0"><li>registration</li></ul>|`true`| Only for `u2f` and `packed` attestation. `tpm` attestation format is always checked against metadata |

  ## FIDO2 Metadata service (MDS) configuration

  The FIDO Alliance provides with a list of metadata statements of certified authenticators.
  A metadata statement contains trust anchors (root certificates) to verify attestations.
  Wax can automatically keep this metadata up to date but needs a access token which is
  provided by the FIDO Alliance. One can request it here:
  [https://mds2.fidoalliance.org/tokens/](https://mds2.fidoalliance.org/tokens/).

  Once the token has been granted, it has to be added in the configuration file (consider
  adding it to your `*.secret.exs` files) with the `:metadata_access_token` key. The update
  frquency can be configured with the `:metadata_update_interval` key (in seconds, defaults
  to 12 hours). Example:

  `config/dev.exs`:
  ```elixir
  use Mix.Config

  config :wax,
    metadata_update_interval: 3600,
  ```

  `config/dev.secret.exs`:
  ```elixir
  use Mix.Config

  config :wax,
    metadata_access_token: "d4904acd10a36f62d7a7d33e4c9a86628a2b0eea0c3b1a6c"
  ```
  """

  @type opts :: Keyword.t()

  @type parsed_opts :: %{required(atom()) => any()}

  @spec set_opts(opts()) :: parsed_opts()

  defp set_opts(kw) do
    origin =
      if is_binary(kw[:origin]) do
        kw[:origin]
      else
        case Application.get_env(:wax, :origin) do
          origin when is_binary(origin) ->
            origin

          _ ->
            raise "Missing mandatory parameter `origin` (String.t())"
        end
      end

    unless URI.parse(origin).host == "localhost" or URI.parse(origin).scheme == "https" do
      raise "Invalid origin `#{origin}` (must be either https scheme or `localhost`)"
    end

    rp_id =
      if kw[:rp_id] == :auto or Application.get_env(:wax, :rp_id) == :auto do
        URI.parse(origin).host
      else
        if is_binary(kw[:rp_id]) do
          kw[:rp_id]
        else
          case Application.get_env(:wax, :rp_id) do
            rp_id when is_binary(rp_id) ->
              rp_id

            _ ->
              raise "Missing mandatory parameter `rp_id` (String.t())"
          end
        end
      end

    %{
      origin: origin,
      rp_id: rp_id,
      user_verified_required:
        if is_boolean(kw[:user_verified_required]) do
          kw[:user_verified_required]
        else
          Application.get_env(:wax, :user_verified_required, false)
        end,
      trusted_attestation_types:
      if is_list(kw[:trusted_attestation_types]) do
        kw[:trusted_attestation_types]
      else
        Application.get_env(:wax,
                            :trusted_attestation_types,
                            [:none, :basic, :uncertain, :attca, :self])
      end,
      verify_trust_root:
        if is_boolean(kw[:verify_trust_root]) do
          kw[:verify_trust_root]
        else
          Application.get_env(:wax, :verify_trust_root, true)
        end
    }
  end

  @doc """
  Generates a new challenge for registration

  The returned structure:
  - Contains the challenge bytes under the `bytes` key (e.g.: `challenge.bytes`). This is a
  random value that must be used by the javascript WebAuthn call
  - Must be passed backed to `register/3`

  Typically, this structure is stored in the session (cookie...) for the time the WebAuthn
  process is performed on the client side.

  ## Example:
  ```elixir
  iex> Wax.new_registration_challenge(trusted_attestation_types: [:basic, :attca])
  %Wax.Challenge{
    allow_credentials: [],
    bytes: <<192, 64, 240, 166, 163, 188, 76, 255, 108, 227, 18, 33, 123, 19, 61,
      3, 166, 195, 190, 157, 24, 207, 210, 179, 180, 136, 10, 135, 82, 172, 134,
      17>>,
    exp: nil,
    origin: "http://localhost:4000",
    rp_id: "localhost",
    token_binding_status: nil,
    trusted_attestation_types: [:basic, :attca],
    user_verified_required: false,
    verify_trust_root: true
  }
  ```
  """

  @spec new_registration_challenge(opts()) :: Wax.Challenge.t()

  def new_registration_challenge(opts) do
    opts = set_opts(opts)

    Wax.Challenge.new(opts)
  end

  @doc """
  Verifies a registration response from the client WebAuthn javascript call

  The input params are:
  - `attestation_object_cbor`: the **raw binary** response from the WebAuthn javascript API.
  When transmitting it back from the browser to the server, it will probably be base64
  encoded. Make sure to decode it before.
  - `client_data_json_raw`: the JSON string (and **not** the decoded JSON) of the client data
  JSON as returned by the WebAuthn javascript API
  - `challenge`: the challenge that was generated beforehand, and whose bytes has been sent
  to the browser and used as an input by the WebAuthn javascript API

  The success return value is of the form:
  `{cose_key, {attestation_type, trust_path, metadata_statement}}`.
  See `t:Wax.Attestation.result/0` for more details. Note, however, that you can use
  the returned metadata statement (if any) to further check the authenticator capabilites.
  For example, the following conditions will only allow attestation generated by
  hardware protected attestation keys:

  ```elixir
  case Wax.register(attestation_object, client_data_json_raw, challenge) do
    {:ok, {cose_key, {_, _, metadata_statement}}} ->
      # tee is for "trusted execution platform"
      if :key_protection_tee in metadata_statement.key_protection or
         :key_protection_secure_element in metadata_statement.key_protection
      do
        register_key(user, credential_id, cose_key)

        :ok
      else
        {:error, :not_hardware_protected}
      end

    {:error, _} = error ->
      error
  end
  ```

  When performing registration, the server has the 3 following pieces of data:
  - user id: specific to the server implementation. Can be a email, login name, or an opaque
  user identifier
  - credential id: an ID returned by the WebAuthn javascript. It is a handle to further
  authenticate the user
  - a cose key: returned by this function, under the form of a map containing a public
  key use for further authentication
  A credential id is related to a cose key, and vice-versa.

  Note that a user can have several (credential id, cose key) pairs, for example if they do
  user different authenticators. The unique key (for storage, etc.) is therefore the tuple
  (user id, credential id).

  In the success case, and after calling `register/3`, a server shall:
  1. Verify that no other user has the same credential id (and should fail otherwise)
  2. Store the new tuple (credential id, cose key) for the user
  """

  @spec register(binary(), Wax.ClientData.raw_string(), Wax.Challenge.t())
  :: {:ok, {Wax.CoseKey.t(), Wax.Attestation.result(), Wax.AuthenticatorData.t()}} | {:error, atom()}

  def register(attestation_object_cbor, client_data_json_raw, challenge) do

    with {:ok, client_data} <- Wax.ClientData.parse_raw_json(client_data_json_raw),
         :ok <- type_create?(client_data),
         :ok <- valid_challenge?(client_data, challenge),
         :ok <- valid_origin?(client_data, challenge),
         :ok <- valid_token_binding_status?(client_data, challenge),
         client_data_hash <- :crypto.hash(:sha256, client_data_json_raw),
         {:ok, %{"fmt" => fmt, "authData" => auth_data_bin, "attStmt" => att_stmt}}
           <- cbor_decode(attestation_object_cbor),
         {:ok, auth_data} <- Wax.AuthenticatorData.decode(auth_data_bin),
         :ok <- valid_rp_id?(auth_data, challenge),
         :ok <- user_present_flag_set?(auth_data),
         :ok <- maybe_user_verified_flag_set?(auth_data, challenge),
         #FIXME: verify extensions
         {:ok, valid_attestation_statement_format?}
           <- Wax.Attestation.statement_verify_fun(fmt),
         {:ok, attestation_result_data}
           <- valid_attestation_statement_format?.(att_stmt,
                                                   auth_data,
                                                   client_data_hash,
                                                   challenge.verify_trust_root),
         :ok <- attestation_trustworthy?(attestation_result_data, challenge)
    do
      {:ok, {
        auth_data.attested_credential_data.credential_public_key,
        attestation_result_data,
        auth_data
      }}
    else
      error ->
        error
    end
  end

  @doc """
  Generates a new challenge for authentication

  The first argument is a list of (credential id, cose key) which were previsouly
  registered (after successful `register/3`) for a user. This can be retrieved from
  a user database for instance.

  The returned structure:
  - Contains the challenge bytes under the `bytes` key (e.g.: `challenge.bytes`). This is a
  random value that must be used by the javascript WebAuthn call
  - Must be passed backed to `authenticate/5`

  Typically, this structure is stored in the session (cookie...) for the time the WebAuthn
  authentication process is performed on the client side.

  ## Example:
  ```elixir
  iex> cred_ids_and_associated_keys = UserDatabase.load_cred_id("Georges")
  [
    {"vwoRFklWfHJe1Fqjv7wY6exTyh23PjIBC4tTc4meXCeZQFEMwYorp3uYToGo8rVwxoU7c+C8eFuFOuF+unJQ8g==",
     %{
       -3 => <<121, 21, 84, 106, 84, 48, 91, 21, 161, 78, 176, 199, 224, 86, 196,
         226, 116, 207, 221, 200, 26, 202, 214, 78, 95, 112, 140, 236, 190, 183,
         177, 223>>,
       -2 => <<195, 105, 55, 252, 13, 134, 94, 208, 83, 115, 8, 235, 190, 173,
         107, 78, 247, 125, 65, 216, 252, 232, 41, 13, 39, 104, 231, 65, 200, 149,
         172, 118>>,
       -1 => 1,
       1 => 2,
       3 => -7
     }},
    {"E0YtUWEPcRLyW1wd4v3KuHqlW1DRQmF2VgNhhR1FumtMYPUEu/d3RO+WC4T4XIa0PZ6Pjw+IBNQDn/It5UjWmw==",
     %{
       -3 => <<113, 34, 76, 107, 120, 21, 246, 189, 21, 167, 119, 39, 245, 140,
         143, 133, 209, 19, 63, 196, 145, 52, 43, 2, 193, 208, 200, 103, 3, 51,
         37, 123>>,
       -2 => <<199, 68, 146, 57, 216, 62, 11, 98, 8, 108, 9, 229, 40, 97, 201,
         127, 47, 240, 50, 126, 138, 205, 37, 148, 172, 240, 65, 125, 70, 81, 213,
         152>>,
       -1 => 1,
       1 => 2,
       3 => -7
     }}
  ]
  iex> Wax.new_authentication_challenge(cred_ids_and_associated_keys, [])
  %Wax.Challenge{
    allow_credentials: [
      {"vwoRFklWfHJe1Fqjv7wY6exTyh23PjIBC4tTc4meXCeZQFEMwYorp3uYToGo8rVwxoU7c+C8eFuFOuF+unJQ8g==",
       %{
         -3 => <<121, 21, 84, 106, 84, 48, 91, 21, 161, 78, 176, 199, 224, 86,
           196, 226, 116, 207, 221, 200, 26, 202, 214, 78, 95, 112, 140, 236, 190,
           183, 177, 223>>,
         -2 => <<195, 105, 55, 252, 13, 134, 94, 208, 83, 115, 8, 235, 190, 173,
           107, 78, 247, 125, 65, 216, 252, 232, 41, 13, 39, 104, 231, 65, 200,
           149, 172, 118>>,
         -1 => 1,
         1 => 2,
         3 => -7
       }},
      {"E0YtUWEPcRLyW1wd4v3KuHqlW1DRQmF2VgNhhR1FumtMYPUEu/d3RO+WC4T4XIa0PZ6Pjw+IBNQDn/It5UjWmw==",
       %{
         -3 => <<113, 34, 76, 107, 120, 21, 246, 189, 21, 167, 119, 39, 245, 140,
           143, 133, 209, 19, 63, 196, 145, 52, 43, 2, 193, 208, 200, 103, 3, 51,
           37, 123>>,
         -2 => <<199, 68, 146, 57, 216, 62, 11, 98, 8, 108, 9, 229, 40, 97, 201,
           127, 47, 240, 50, 126, 138, 205, 37, 148, 172, 240, 65, 125, 70, 81,
           213, 152>>,
         -1 => 1,
         1 => 2,
         3 => -7
       }}
    ],
    bytes: <<130, 70, 153, 38, 189, 145, 193, 3, 132, 158, 170, 216, 8, 93, 221,
      46, 206, 156, 104, 24, 78, 167, 182, 5, 6, 128, 194, 201, 196, 246, 243,
      194>>,
    exp: nil,
    origin: "http://localhost:4000",
    rp_id: "localhost",
    token_binding_status: nil,
    trusted_attestation_types: [:none, :basic, :uncertain, :attca, :self],
    user_verified_required: false,
    verify_trust_root: true
  }
  ```
  """

  @spec new_authentication_challenge([{Wax.CredentialId.t(), Wax.CoseKey.t()}], opts())
    :: Wax.Challenge.t()

  def new_authentication_challenge(allow_credentials, opts) do
    opts = set_opts(opts)

    Wax.Challenge.new(allow_credentials, opts)
  end

  @doc """
  Verifies a authentication response from the client WebAuthn javascript call

  The input params are:
  - `credential id`: the credential id returned by the WebAuthn javascript API. Must be of
  the same form as the one passed to `new_authentication_challenge/2` as it will be
  compared against the previously retrieved valid credential ids
  - `auth_data_bin`: the authenticator data returned by the WebAuthn javascript API. Must
  be the raw binary, not the base64 encoded form
  - `sig`: the signature returned by the WebAuthn javascript API. Must
  be the raw binary, not the base64 encoded form
  - `client_data_json_raw`: the JSON string (and **not** the decoded JSON) of the client data
  JSON as returned by the WebAuthn javascript API
  - `challenge`: the challenge that was generated beforehand, and whose bytes has been sent
  to the browser and used as an input by the WebAuthn javascript API

  The call returns `{:ok, sign_count}` in case of success, or `{:error, :reason}` otherwise.
  The `sign_count` is the number of signature performed by this authenticator for this
  credential id, and can be used to detect cloning of authenticator. See point 17 of the
  [7.2. Verifying an Authentication Assertion](https://www.w3.org/TR/2019/PR-webauthn-20190117/#verifying-assertion)
  for more details.
  """
  @spec authenticate(Wax.CredentialId.t(),
                     binary(),
                     binary(),
                     Wax.ClientData.raw_string(),
                     Wax.Challenge.t()
  ) :: {:ok, non_neg_integer(), Wax.AuthenticatorData.t()} | {:error, any()}

  def authenticate(credential_id,
                   auth_data_bin,
                   sig,
                   client_data_json_raw,
                   challenge) do
    with {:ok, cose_key} <- cose_key_from_credential_id(credential_id, challenge),
         {:ok, auth_data} <- Wax.AuthenticatorData.decode(auth_data_bin),
         {:ok, client_data} <- Wax.ClientData.parse_raw_json(client_data_json_raw),
         :ok <- type_get?(client_data),
         :ok <- valid_challenge?(client_data, challenge),
         :ok <- valid_origin?(client_data, challenge),
         :ok <- valid_token_binding_status?(client_data, challenge),
         :ok <- valid_rp_id?(auth_data, challenge),
         :ok <- user_present_flag_set?(auth_data),
         :ok <- maybe_user_verified_flag_set?(auth_data, challenge),
         #FIXME: verify extensions
         client_data_hash <- :crypto.hash(:sha256, client_data_json_raw),
         :ok <- Wax.CoseKey.verify(auth_data_bin <> client_data_hash, cose_key, sig)
    do
      {:ok, auth_data.sign_count, auth_data}
    else
      error ->
        error
    end
  end

  @spec type_create?(Wax.ClientData.t()) :: :ok | {:error, atom()}

  defp type_create?(client_data) do
    if client_data.type == :create do
      :ok
    else
      {:error, :attestation_invalid_type}
    end
  end

  @spec type_get?(Wax.ClientData.t()) :: :ok | {:error, atom()}

  defp type_get?(client_data) do
    if client_data.type == :get do
      :ok
    else
      {:error, :attestation_invalid_type}
    end
  end

  @spec valid_challenge?(Wax.ClientData.t(), Wax.Challenge.t()) :: :ok | {:error, any()}

  defp valid_challenge?(client_data, challenge) do
    if client_data.challenge == challenge.bytes do
      :ok
    else
      {:error, :invalid_challenge}
    end
  end

  @spec valid_origin?(Wax.ClientData.t(), Wax.Challenge.t()) :: :ok | {:error, atom()}

  defp valid_origin?(client_data, challenge) do
    if client_data.origin == challenge.origin do
      :ok
    else
      {:error, :attestation_invalid_origin}
    end
  end

  @spec valid_token_binding_status?(Wax.ClientData.t(), Wax.Challenge.t())
    :: :ok | {:error, atom()}

  defp valid_token_binding_status?(_client_data, _challenge), do: :ok #FIXME: implement?

  defp cbor_decode(cbor) do
    try do
      Logger.debug("#{__MODULE__}: decoded attestation object: " <>
        "#{inspect(:cbor.decode(cbor), pretty: true)}")
      {:ok, :cbor.decode(cbor)}
    catch
      _ -> {:error, :invalid_cbor}
    end
  end

  @spec valid_rp_id?(Wax.AuthenticatorData.t(), Wax.Challenge.t()) :: :ok | {:error, atom()}
  defp valid_rp_id?(auth_data, challenge) do
    if auth_data.rp_id_hash == :crypto.hash(:sha256, challenge.rp_id) do
      :ok
    else
      {:error, :invalid_rp_id}
    end
  end

  @spec user_present_flag_set?(Wax.AuthenticatorData.t()) :: :ok | {:error, any()}
  defp user_present_flag_set?(auth_data) do
    if auth_data.flag_user_present == true do
      :ok
    else
      {:error, :flag_user_present_not_set}
    end
  end

  @spec maybe_user_verified_flag_set?(Wax.AuthenticatorData.t(), Wax.Challenge.t())
    :: :ok | {:error, atom()}
  defp maybe_user_verified_flag_set?(auth_data, challenge) do
    if !challenge.user_verified_required or auth_data.flag_user_verified do
      :ok
    else
      {:error, :user_not_verified}
    end
  end

  @spec attestation_trustworthy?(Wax.Attestation.result(), Wax.Challenge.t())
    :: :ok | {:error, any()}

  defp attestation_trustworthy?({type, _, _}, %Wax.Challenge{trusted_attestation_types: tatl})
  do
    if type in tatl do
      :ok
    else
      {:error, :untrusted_attestation_type}
    end
  end

  @spec cose_key_from_credential_id(Wax.CredentialId.t(), Wax.Challenge.t())
    :: {:ok, Wax.CoseKey.t()} | {:error, any()}

  defp cose_key_from_credential_id(credential_id, challenge) do
    case List.keyfind(challenge.allow_credentials, credential_id, 0) do
      {_, cose_key} ->
        {:ok, cose_key}

      _ ->
        {:error, :incorrect_credential_id_for_user}
    end
  end
end
