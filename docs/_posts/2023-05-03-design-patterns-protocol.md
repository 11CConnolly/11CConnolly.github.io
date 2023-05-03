---
layout:post
title: design-patterns-protocol
date: Wed May  3 20:19:49 BST 2023
categories: 
---
Currently, my team at work is building an implementation of the CCSDS File Delivery Protocol (CFDP) to enable the transfer of files satellite to satellite, satellite to ground, or ground to satellite; it is the same file delivery protocol used on the James Webb Space Telescope.

A quick primer on this extraterrestrial protocol. Each running implementation of CFDP, or protocol entity, is assigned a unique _entity ID_. We receive _requests_ to copy files from one entity ID to another, and we interact with the onboard file store to get the data we want to send, and send this information in messages called _PDUs_. We also need to receive these incoming PDUs at the same time (there is some multiplexing going on via spacewire which enables this) and store these in our onboard file store.

Getting this application to work is complicated, very detail-oriented, and designed to run on either ground or space. This sets us up with some interesting problems to solve. How do we write this in such a way to run on different kinds of platforms, across different underlying networking protocols, and with distinct file systems? How do we ensure it is extensible enough to run efficiently on ground with a lot of computational resources and efficient enough to run with limited memory executing on more restricted space hardware? How do we make this as efficient as possible, with the advanced in space certified multitasking Operating Systems and radiation hardened multicore processors?

As the architect for this project, some of the high-level decisions that we made are as follows:

#### JPL Recommended Implementation

After reading the CCSDS Green and Blue Books, we decided to base our approach on a mix between the JPL recommended implementation and the BNSC Approach to the development of CFDP; utilizing one set of procedures to receive requests, package new data up, and receive incoming packets, (our daemon) and another to radiate our data packets (our dispatch). We stored these data packets in operating system message queues (bypassing the limited application stack) between packaging and radiation. You can read more about each implementation [here](https://public.ccsds.org/Publications/default.aspx). By following this implementation, we ensured that our CFDP application has as much autonomy as possible to execute, minimizing file-sending time, and improving the efficiency of our application. To tailor it across different platforms we can increase or decrease the size of our message queues.

#### Multitasking

After deciding upon our separation of procedures and concerns, we leveraged the ability of multitasking from the newly qualified RTEMS SMP (qualification work for ESA I was also part of, along with several other organizations including Gaisler and Trinity College) to run our daemon as one task, and our dispatch another. With this approach, we could operate in parallel to drastically improve efficiency. The only concern was that we had to purposefully lock and unlock our outgoing buffers with mutexes to prevent any race conditions.

#### Not allowing unbounded files

An exceptionally lucid point raised by our line manager during our initial run-down of the protocol was that when receiving packets of data either deliberately unbounded or with an unknown Entity ID, we would be consuming and storing a potentially unlimited amount of data. Handling potentially infinite streams of data in an application with limited stack, execution time, and resources creates definite memory issues and is a potential attack vector for a threat actor (This is assuming they already know the Entity IDs, APIDs, and have an active communications link, however, it is surprisingly [easy to hack satellites](https://www.welivesecurity.com/2021/06/07/hacking-space-how-pwn-satellite/)). Therefore we decided against handling these unbounded sizes of data packets or unknown packets by outright rejecting them.

#### Not using 'proper' polymorphism in C

The idea of the protocol is the transfer PDUs which encapsulate file data, or to support the transfer of the file. Certain classes of PDU share similar properties and functionality of others, leaving them wide open to an Object Oriented approach. In C, polymorphism is implemented by having pointers to structs being cast to pointers of different structs at run-time. Unfortunately, according to MISRA rules we are not allowed to do this, due to memory alignment issues, leading to implementing a more restricted version solely using function pointers and macros. This allows us some run-time flexibility without memory alignment issues. This will come into play during the next few sections.

Now without further ado, let's get into the thetic point of this post - the design patterns we used for our extraterrestrial networking protocol.

## Command: Behavioural Pattern

Problem: We need to be able to take in any number of requests to send files from one place to another, to be able to process these at a later date, and then to create the necessary packets of data if and when required

Pattern Intent: Command is a behavioral design pattern that turns a request into a stand-alone object that contains all information about the request. This transformation lets you pass requests as method arguments, delay or queue a request’s execution, and support undoable operations.

Implementation: The 'meat and potatoes' of our CFDP application is the transactions list, a statically allocated list that keeps track of all our incoming and outgoing file transfers. We can take in a request and extract all the information that we need from it so then at a later date we can process this request. Or when it comes to receiving missing files, we can be clear about which files are missing and which files are from properties on this transaction object.

## State: Behavioural Pattern

Problem: We need to keep track of the changes that have happened to our transactions and send or receive the appropriate data at the right time.

Pattern Intent: State is a behavioral design pattern that lets an object alter its behavior when its internal state changes. It appears as if the object changed its class.

Implementation: Each transaction has a particular class and a set of states it can be in. These states will follow a predefined FSM so that when it comes to reading from our transactions list, we can quickly tell each transaction to process itself based on a defined function in the transaction object. This utilizes a limited set of polymorphism mentioned previously - using function pointers and macro constructors - which allows us some degree of flexibility regarding the specific executing behavior of our transaction. Still, without proper polymorphism, we cannot assume the properties of these objects.

What this looks like in C code (not our actual production code):

```
typedef struct
{
    void (*process)(struct tx_t);             // Function pointer to address for each class of transaction
                                              // To process itself
    tx_state                state;            // Enum from a set of predefined values
    header_variables_t      header_variables; // Header variables as each PDU will need these
    missing_file_sections_t missing_sections; // Missing sections (as integers) for a filedata PDU
    uint32_t                NAK_retry_timer;  // TODO Expand upon this
} tx_t;

typedef uint8_t missing_file_sections_t[MAX_MISSING_PDUS];

// Get the transaction to generically call itself and process itself with it's
// particular state machine
#define PROCESS_TRANSACTION(tx) tx.process(tx);

// Macro constructor for initialising and defining a Class 1 Sending Transaction
#define CLASS_1_SENDER(tx)                \
    tx_t tx;                              \
    tx.process = &process_class_1_sender; \
    tx.state = TXN_SEND_METADATA_PDU;
```

## Bridge: Structural Pattern

Problem: As mentioned in the introduction, the idea for our CFDP Application is to effectively become a Software Product built across several different overlying and underlying interfaces.

Pattern Intent: Bridge is a structural design pattern that lets you split a large class or a set of closely related classes into two separate hierarchies—abstraction and implementation—which can be developed independently of each other.

Whilst this concept is much more applicable to Object Oriented programming, the solution of separation of implementation and interfaces is an important one that we can apply for our application. The idea of it is that it will be able to interface, in the future, with different Operating Systems, different Schedulers, and different underlying network procedures (TCP, UDP, SPP, Bundle Protocol) with specific compilation time definitions and includes. Architecture independence means code can be reused, giving greater stability through flight heritage - one of the core tenets of space software code.
