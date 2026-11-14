import { Sockets } from 'capacitor-plugin-sockets';

window.testEcho = () => {
    const inputValue = document.getElementById("echoInput").value;
    Sockets.echo({ value: inputValue })
}
