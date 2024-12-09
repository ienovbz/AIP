import json
import requests
from requests_toolbelt import MultipartEncoder
import argparse
import subprocess
import re

def extract_url(pem_file):
    # Construct the command
    command = [
        'openssl',
        'x509',
        '-in', pem_file,
        '-noout', '-subject'
    ]

    # Run the command and capture the output
    result = subprocess.run(command, stdout=subprocess.PIPE, text=True)

    # Extract the CN from the output using a similar regex as before
    cn_match = re.search(r'^\s*subject.*CN\s*=\s*([^\/]+)', result.stdout, re.MULTILINE)

    # Check if the CN match was found
    if cn_match:
        cn_value = cn_match.group(1).strip()
        print("Common Name (CN):", cn_value)
        return cn_value
    else:
        print("Unable to extract Common Name (CN) from the certificate.")


def rest_post(session, url, payload, payload_type):
    headers = {
        'Content-Type': payload_type
    }
    response = session.post(url, headers=headers, data=payload)

    if response.status_code == 201:
        try:
            j = response.json()
            if isinstance(j, list):
                link = j[0]["_links"]["self"]["href"]
                index = j[0]["id"]
            else:
                link = j["_links"]["self"]["href"]
                index = j["id"]
        except (KeyError, IndexError):
            print("Bad response" + str(response.json()))
            return "", 0

        return link, index
    elif response.status_code == 200:
        return "OK", 0
    else:
        return "", 0


def add_software_module(session, base_url, name, vendor, description, version):
    payload = json.dumps([
        {
            "name": name,
            "vendor": vendor,
            "description": description,
            "type": "os",
            "version": version
        }
    ])
    url = "https://" + base_url + ":8443/rest/v1/softwaremodules"
    return rest_post(session, url, payload, 'application/json')


def add_distribution_set(session, base_url, name, description, version, ):
    payload = json.dumps([
        {
            "name": name,
            "description": description,
            "version": version,
            "requiredMigrationStep": False,
            "type": "os_app"
        }
    ])
    url = "https://" + base_url + ":8443/rest/v1/distributionsets"
    return rest_post(session, url, payload, 'application/json')


def add_filter(session, base_url, name, query):
    payload = json.dumps(
        {
            "name": name,
            "query": query
        }
    )
    url = "https://" + base_url + ":8443/rest/v1/targetfilters"
    return rest_post(session, url, payload, 'application/json')


def upload_software_artifact(session, base_url, file_name, sm_id):
    url = "https://" + base_url + ":8443/rest/v1/softwaremodules/" + str(sm_id) + "/artifacts"

    encoder = MultipartEncoder(
        fields={'file': ('Albireo.swu', open(file_name, 'rb'), 'text/plain')}
    )
    return rest_post(session, url, encoder, encoder.content_type)


def link_software_module(session, base_url, dist_id, sm_id):
    payload = json.dumps([
        {
            "id": sm_id
        }
    ])

    url = "https://" + base_url + ":8443/rest/v1/distributionsets/" + str(dist_id) + "/assignedSM"
    return rest_post(session, url, payload, 'application/json')


def add_software_release(user, passwd, system_type, url, version, pem_file):
    session = requests.session()
    session.auth = (user, passwd)
    session.verify = pem_file

    print("Trying to verify ", url, user, passwd, pem_file)

    if system_type == 'IC':
        name = "Albireo INEX Cloud"
        description = "Albireo Software for INEX Cloud"
        add_filter(session, url, "IC lt " + version,
                   "attribute.version =lt= " + version + " AND attribute.system == 'Inex Cloud'")
    elif system_type == 'I500':
        name = "Albireo INEX 500"
        description = "Albireo Software for INEX 500"
        add_filter(session, url, "I500 lt " + version,
                   "attribute.version =lt= " + version + " AND attribute.system == 'Inex 500'")
    else:
        print("no valid system was provided")
        exit(1)

    vendor = "van Breda"
    ds = add_distribution_set(session, url, name, description, version)
    if not ds[0]:
        print("Could not add Distribution set for", name, version)
        print("Check if a Distribution set with this name already exists and delete it  (as well as the software "
              "module)")
        exit(1)

    print("Added distribution set at index: ", str(ds[1]))

    sm = add_software_module(session, url, name, vendor, description, version)
    if not sm[0]:
        print("Could not add software module for", name, version)
        print(
            "Check if a software module with this name already exists and delete it (as well as the Distribution set)")
        exit(1)

    print("Added software module set at index: ", str(sm[1]))

    sa = upload_software_artifact(session, url, "swu-image-albireo.swu", sm[1])
    if not sa[0]:
        print("Could not upload software artifact for", name, version)
        exit(1)

    print("Uploaded software artifact to software module at index: ", str(sm[1]))

    sl = link_software_module(session, url, ds[1], sm[1])
    if not sl[0]:
        print("Could not link software module " + str(sm[1]) + " to distribution set " + str(ds[1]))
        exit(1)

    print("Linked software module: " + str(sm[1]) + " to distribution set: " + str(ds[1]))
    print("Upload succeeded")


# Press the green button in the gutter to run the script.
if __name__ == '__main__':

    outfile = open("versions.txt", "r")
    data = outfile.readlines()
    release_version = ""
    system = ""

    for line in data:
        if 'Release' in line:
            release_line = line
            words = release_line.split(':')
            release_version = words[1].strip("\"\n\" ").split('+')[0]
            print("The release version is: " + release_version)
        if 'System' in line:
            system = line.split(':')[1].strip("\n ")
            print("The target system is: " + system)

    if not release_version:
        print("There was no release version found in versions.txt")
        exit(1)

    if not system:
        print("There was no system found in versions.txt")
        exit(1)

    parser = argparse.ArgumentParser(description="Deploy script used to upload a software artifact to a Hawkbit server",
                                     formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument("-u", "--user", default="admin", help="User name")
    parser.add_argument("-p", "--pass", help="Password", required=True)
    parser.add_argument("-U", "--URL", default="", help="The URL of the Hawkbit server")
    parser.add_argument("-c", "--cert", default="", help="The name of the .pem certificate file")
    args = parser.parse_args()
    config = vars(args)

    cert = "hawkbit.pem"
    if config["cert"]:
        cert = config["cert"]

    url = "hawkbit.local"

    if config["URL"]:
        url = config["URL"]
    else:
        url = extract_url(cert)

    print("extracted url is: ", url)
    add_software_release(config["user"], config["pass"], system, url, release_version, cert)
