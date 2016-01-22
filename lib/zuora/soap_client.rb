require 'faraday'
require 'faraday_middleware'
require 'nokogiri'

module Zuora
  # Unable to connect. Check username / password
  SoapConnectionError = Class.new StandardError

  # Non-success response
  SoapErrorResponse = Class.new StandardError

  class SoapClient
    attr_accessor :session_token

    SOAP_API_URI = '/apps/services/a/74.0'.freeze
    SESSION_TOKEN_XPATH =
      %w(//soapenv:Envelope soapenv:Body ns1:loginResponse
         ns1:result ns1:Session).join('/').freeze

    NAMESPACES = {
      'xmlns:soapenv' => 'http://schemas.xmlsoap.org/soap/envelope/',
      'xmlns:ns1' => 'http://api.zuora.com/',
      'xmlns:ns2' => 'http://object.api.zuora.com/',
      'xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance'
    }.freeze

    # Creates a connection instance.
    # Makes an initial SOAP request to fetch session token.
    # Subsequent requests contain the authenticated session id
    # in headers.
    # @param [String] username
    # @param [String] password
    # @param [Boolean] sandbox
    # @return [Zuora::SoapClient]
    def initialize(username, password, sandbox = true)
      @username = username
      @password = password
      @sandbox = sandbox
    end

    # Makes auth request, handles response
    # @return [Faraday::Response]
    def authenticate!
      auth_response(request(login_request_xml))
    rescue Object => e
      raise SoapConnectionError, e
    end

    REFUND_FIELDS = [
      :AccountId,
      :Amount,
      :PaymentId,
      :Type

    ].freeze

    BILL_RUN_FIELDS = [
      :AccountId,
      :AutoEmail,
      :AutoPost,
      :AutoRenewal,
      :Batch,
      :BillCycleDay,
      :ChargeTypeToExclude,
      :Id,
      :InvoiceDate,
      :NoEmailForZeroAmountInvoice,
      :Status,
      :TargetDate
    ].freeze

    Z_OBJECTS = { Refund: REFUND_FIELDS,
                  BillRun: BILL_RUN_FIELDS }.freeze

    # Dynamically generates methods that create zobject xml
    Z_OBJECTS.each do |z_object_name, fields|
      object_name = z_object_name.to_s.underscore
      create_xml_method_name = "create_#{object_name}_xml"
      create_request_method_name = "create_#{object_name}!"

      # Generates XML builder for given Z-object using data
      # @params [Hash] data - hash of data for the new z-object
      define_method(create_xml_method_name) do |data = {}|
        create_object_xml z_object_name, fields, data
      end

      # Fires a create ___ request sending XML envelope for Z-Object
      # @params [Hash] data - hash of data for the new z-object
      # @return [Faraday::Response]
      define_method(create_request_method_name) do |data = {}|
        request send(create_xml_method_name, data)
      end
    end

    # Generates a SOAP envelope for given Zuora object
    # of `type`, having `fields`, with `data`
    # @params [Symbol] type e.g. :BillRun, :Refund
    # @params [Array] fields - hash of whitelisted zuora object field names
    # @return [Nokogiri::Xml::Builder] - SOAP envelope
    def create_object_xml(type, fields, data)
      authenticated_envelope_xml do |builder|
        builder[:ns1].create do
          builder[:ns1].zObjects('xsi:type' => "ns2:#{type}") do
            fields.each do |field|
              value = data[field.to_s.underscore.to_sym]
              builder[:ns2].send(field, value) if value
            end
          end
        end
      end
    end

    private

    # Fire a request
    # @param [Xml] body - an object responding to .xml
    # @return [Faraday::Response]
    def request(body)
      fail 'body must support .to_xml' unless body.respond_to? :to_xml

      connection.post do |request|
        request.url SOAP_API_URI
        request.headers['Content-Type'] = 'text/xml'
        request.body = body.to_xml
      end
    end

    # Handle auth response, setting session
    # @params [Faraday::Response]
    # @return [Faraday::Response]
    # @throw [SoapErrorResponse]
    def auth_response(response)
      if response.status == 200
        @session_token = extract_session_token response
      else
        message = 'Unable to connect with provided credentials'
        fail SoapErrorResponse, message
      end
      response
    end

    # Extracts session token from response and sets instance variable
    # for use in subsequent requests
    # @param [Faraday::Response] response - response to auth request
    def extract_session_token(response)
      Nokogiri::XML(response.body).xpath(SESSION_TOKEN_XPATH, NAMESPACES).text
    end

    # Generates Login Envelope XML builder
    def login_request_xml
      username = @username
      password = @password

      body = lambda do |builder|
        builder[:ns1].login do
          builder[:ns1].username(username)
          builder[:ns1].password(password)
        end
        builder
      end

      envelope_xml nil, body
    end

    # Initializes a connection using api_url
    # @return [Faraday::Connection]
    def connection
      Faraday.new(api_url, ssl: { verify: false }) do |conn|
        conn.adapter Faraday.default_adapter
      end
    end

    # @return [String] - SOAP url based on @sandbox
    def api_url
      if @sandbox
        'https://apisandbox.zuora.com/apps/services/a/74.0'
      else
        'https://api.zuora.com/apps/services/a/74.0'
      end
    end

    # Takes a body, and returns an envelope with session header token merged in
    # @param [Callable] body - function of body
    # @return [Nokogiri::Xml::Builder]
    def authenticated_envelope_xml(&body)
      failure_message = 'Session token not set. Did you call authenticate? '
      fail failure_message unless @session_token.present?

      token = @session_token

      header = lambda do |builder|
        builder[:ns1].SessionHeader do
          builder[:ns1].session(token)
        end
        builder
      end

      envelope_xml(header, body)
    end

    # @param [Callable] header - optional function of builder, returns builder
    # @param [Callable] body  - optional function of builder, returns builder
    def envelope_xml(header, body)
      builder = Nokogiri::XML::Builder.new
      builder[:soapenv].Envelope(NAMESPACES) do
        builder[:soapenv].Header do
          header.call builder
        end if header
        builder[:soapenv].Body do
          body.call builder
        end if body
      end
      builder
    end
  end
end
