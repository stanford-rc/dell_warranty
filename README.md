# dell_warranty
CLI + REST API to check Dell hardware warranty information.

## Description

`dell_warranty` is a simple script to retrieve warranty information about Dell
hardware.

It pulls information from the [Dell support](support.dell.com) website and
presents it in either plain-text or JSON format. It can be used as a CLI, or
as a REST API to facilitate queries via web services.

### Why?

Dell does provide a Warranty API for its customers. To use it, you'll need to:
* register for an API key,
* develop a mechanism to handle OAuth2 authentication,
* renew tokens every hour,
* renew your API key every year,
* make sure you're good at implementing [exponential
  backoff](https://en.wikipedia.org/wiki/Exponential_backoff),
* be prepared for inconsistent, inaccurate or simply missing information about
  your servers.

In the meantime, the same information is freely available on
https://support.dell.com and can be retrieved without any of the inconveniences
listed above. `dell_warranty` uses that. No API key registration required.


## Installation

It's a shell script.


### Dependencies

For the CLI:
* `bash`
* [HTTPie](https://httpie.org): command-line HTTP client
* [pup](https://github.com/ericchiang/pup): command-line HTML parser
* [jo](https://github.com/jpmens/jo): command-line JSON generator

To run the API server:
* [shell2http](https://github.com/msoap/shell2http): a HTTP server for shell
  commands


## Usage

```
Usage:  dell_warranty.sh [-j] [-e] <service_tag>

        -j  output data is serialized as a JSON object
        -e  only display the warranty expiration date
```

Example output:

```
$ ./dell_warranty.sh <service_tag>
===========================================
 PowerEdge R630
===========================================
 service tag         | <service_tag>
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

JSON output:
```
$ ./dell_warranty -j <service_tag>
{
   "product": "PowerEdge R630",
   "svctag": "<service_tag>",
   "ship_date": "2016-10-19",
   "warranty_type": "ProSupport",
   "warranty_status": "InWarranty",
   "warranty_expiration_date": "2020-10-20",
   "support_services": [
      {
         "service": "ProSupport Mission Critical",
         "start_date": "2016-10-19",
         "end_date": "2020-10-20"
      },
      {
         "service": "4 Hour On-Site Service",
         "start_date": "2019-10-20",
         "end_date": "2020-10-21"
      }
   ]
}
```


### REST API


To start the API server, you can either:

* use [`shell2http`](https://github.com/msoap/shell2http) directly, and run:
  ```
  $ shell2http -form /check './dell_warranty.sh -j $v_svctag'
  2020/07/14 09:36:36 register: /check (./dell_warranty.sh -j $v_svctag)
  2020/07/14 09:36:36 register: / (index page)
  2020/07/14 09:36:36 listen http://:8080/
  ```
* or use Docker:
  ```
  $ docker build -t dell_warranty_api .
  $ docker run -t dell_warranty_api
  2020/07/14 18:43:40 register: /check (/app/dell_warranty.sh -j $v_svctag)
  2020/07/14 18:43:40 listen http://localhost:8080/
  ```

* or directly deploy to [Railway](railway.app):

  [![Deploy on Railway](https://railway.app/button.svg)](https://railway.app/template/23biGs?referralCode=KL3ssj)


And then, you can query the API server with:
  ```
  $ curl http://localhost:8080/check?svctag=<servicetag>
  {
     "product": "PowerEdge R630",
     "svctag": "<servicetag>",
     "ship_date": "2016-10-19",
     "warranty_type": "ProSupport",
     "warranty_status": "InWarranty",
     "warranty_expiration_date": "2020-10-20",
     "support_services": [
      {
       "service": "ProSupport Mission Critical",
       "start_date": "2016-10-19",
       "end_date": "2020-10-20"
      },
      {
       "service": "4 Hour On-Site Service",
       "start_date": "2019-10-20",
       "end_date": "2020-10-21"
      }
     ]
  }
```

