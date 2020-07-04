# dell_warranty
CLI tool + REST API to check Dell hardware warranty information.

## Description

`dell_warranty` is a simple script to retrieve warranty information about Dell hardware. 

It pulls information from the [Dell support](support.dell.com) website and presents it in either plain-text or JSON format. It can be used as a CLI, or through a REST API to facilitate queries via web services.

### Why?

Dell provides a Warranty API for its customers. To use it, you'll need to:
* register for an API key,
* develop a mechanism to handle OAuth2 authentication with 1-hour lifetime tokens,
* renew your API key every year,
* make sure you're good at implementing [exponential backoff](https://en.wikipedia.org/wiki/Exponential_backoff),
* be prepared for inconsistent, inaccurate or simply missing information about your servers.

In the meantime, the same information is freely available on https://support.dell.com and can be retrieved without any of the inconveniences listed above. `dell_warranty` uses that. No API key registration required.


## Installation

It's a shell script.

### Dependencies

For the CLI:
* `bash`
* [HTTPie](https://httpie.org): command-line HTTP client
* [pup](https://github.com/ericchiang/pup): command-line HTML parser
* [jo](https://github.com/jpmens/jo): command-line JSON generator

To run the API server:
* [shell2http](https://github.com/msoap/shell2http): a HTTP server for shell commands


## Usage

```
Usage:  dell_warranty.sh [-j] [-e] <service_tag>

        -j  output data is serialized as a JSON object
        -e  only display the warranty expiration date

```

Example output:

```
===========================================
 PowerEdge R630
===========================================
 service tag         | <redacted>
 ship date           | 2016-10-19
-------------------------------------------
 warranty type       | ProSupport
 warranty status     | InWarranty
 warranty expiration | 2020-10-20
-------------------------------------------
 ProSupport Mission Critical
   start date: 2016-10-19
   end   date: 2020-10-20
-------------------------------------------
 4 Hour On-Site Service
   start date: 2019-10-20
   end   date: 2020-10-21
-------------------------------------------
```

### REST API
TBD

### Example usecases
TBD (spreadsheet)

